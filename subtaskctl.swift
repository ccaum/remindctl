import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge
//  Uses dlopen + NSClassFromString to interact with
//  Apple's private ReminderKit.framework for subtasks
// --------------------------------------------------

final class ReminderKitBridge {
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var isLoaded = false
    
    /// Load ReminderKit.framework dynamically
    @discardableResult
    static func loadFramework() -> Bool {
        if isLoaded { return true }
        
        let paths = [
            "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
            "/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal"
        ]
        
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                frameworkHandle = handle
                isLoaded = true
                return true
            }
        }
        
        return false
    }
    
    /// Check if ReminderKit classes are available
    static var isAvailable: Bool {
        loadFramework()
        return NSClassFromString("REMSaveRequest") != nil && NSClassFromString("REMStore") != nil
    }
}

// --------------------------------------------------
//  EventKit Store for basic reminder access
// --------------------------------------------------

class EventKitBridge {
    let eventStore = EKEventStore()
    
    func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        
        eventStore.requestFullAccessToReminders { success, error in
            granted = success
            semaphore.signal()
        }
        
        semaphore.wait()
        return granted
    }
    
    func reminder(withID id: String) -> EKReminder? {
        return eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }
    
    func listReminders(in listName: String?) -> [EKReminder] {
        let calendars: [EKCalendar]
        if let listName = listName {
            calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        
        let predicate = eventStore.predicateForReminders(in: calendars)
        eventStore.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            semaphore.signal()
        }
        
        semaphore.wait()
        return result
    }
}

// --------------------------------------------------
//  SQLite Database Access for Subtask Relationships
// --------------------------------------------------

struct SubtaskInfo {
    let parentID: String?
    let displayOrder: Int
}

func fetchSubtaskInfoFromDB() -> [String: SubtaskInfo] {
    var results: [String: SubtaskInfo] = [:]
    
    let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    let fileManager = FileManager.default
    
    guard let enumerator = fileManager.enumerator(atPath: storesPath) else { return results }
    
    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix(".sqlite") {
            let dbPath = (storesPath as NSString).appendingPathComponent(file)
            
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                let query = """
                SELECT r1.ZDACALENDARITEMUNIQUEIDENTIFIER, r2.ZDACALENDARITEMUNIQUEIDENTIFIER, r1.ZICSDISPLAYORDER
                FROM ZREMCDREMINDER r1
                LEFT JOIN ZREMCDREMINDER r2 ON r1.ZPARENTREMINDER = r2.Z_PK
                WHERE r1.ZDACALENDARITEMUNIQUEIDENTIFIER IS NOT NULL;
                """
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let idPtr = sqlite3_column_text(statement, 0) else { continue }
                        let id = String(cString: idPtr)
                        let parentID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                        let order = Int(sqlite3_column_int(statement, 2))
                        
                        results[id] = SubtaskInfo(parentID: parentID, displayOrder: order)
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_close(db)
            }
        }
    }
    return results
}

// Import SQLite
@_silgen_name("sqlite3_open_v2")
func sqlite3_open_v2(_ filename: UnsafePointer<CChar>?, _ ppDb: UnsafeMutablePointer<OpaquePointer?>?, _ flags: Int32, _ zVfs: UnsafePointer<CChar>?) -> Int32

@_silgen_name("sqlite3_close")
func sqlite3_close(_ db: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_prepare_v2")
func sqlite3_prepare_v2(_ db: OpaquePointer?, _ zSql: UnsafePointer<CChar>?, _ nByte: Int32, _ ppStmt: UnsafeMutablePointer<OpaquePointer?>?, _ pzTail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32

@_silgen_name("sqlite3_step")
func sqlite3_step(_ stmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_finalize")
func sqlite3_finalize(_ stmt: OpaquePointer?) -> Int32

@_silgen_name("sqlite3_column_text")
func sqlite3_column_text(_ stmt: OpaquePointer?, _ iCol: Int32) -> UnsafePointer<UInt8>?

@_silgen_name("sqlite3_column_int")
func sqlite3_column_int(_ stmt: OpaquePointer?, _ iCol: Int32) -> Int32

let SQLITE_OK: Int32 = 0
let SQLITE_ROW: Int32 = 100
let SQLITE_OPEN_READONLY: Int32 = 1

// --------------------------------------------------
//  Create Subtask using ReminderKit Private APIs
// --------------------------------------------------

func createSubtask(parentID: String, title: String) {
    // Ensure ReminderKit is loaded
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
    // Get required classes
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
        print("❌  REMStore class not found")
        return
    }
    
    guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
        print("❌  REMSaveRequest class not found")
        return
    }
    
    // Request EventKit access to verify the parent exists
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Fetch the parent REMReminder using the direct method
    let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
    guard store.responds(to: fetchSel) else {
        print("❌  REMStore does not support fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
        return
    }
    
    typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
        print("❌  Failed to get fetch method implementation")
        return
    }
    let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
    
    var fetchError: NSError? = nil
    guard let parentREMReminder = fetchImp(store, fetchSel, parentID as NSString, nil, &fetchError) as? NSObject else {
        let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
        print("❌  Failed to fetch parent reminder: \(errorMsg)")
        return
    }
    
    // 3. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 4. Call updateReminder: to get the parent's change item
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard saveRequest.responds(to: updateReminderSel),
          let parentChangeItem = saveRequest.perform(updateReminderSel, with: parentREMReminder)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get parent reminder change item")
        return
    }
    
    // 5. Get subtaskContext from the parent change item
    let subtaskContextSel = NSSelectorFromString("subtaskContext")
    guard parentChangeItem.responds(to: subtaskContextSel),
          let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get subtask context from parent")
        return
    }
    
    // 6. Use addReminderWithTitle:toReminderSubtaskContextChangeItem: to create the subtask
    let addSubtaskSel = NSSelectorFromString("addReminderWithTitle:toReminderSubtaskContextChangeItem:")
    guard saveRequest.responds(to: addSubtaskSel) else {
        print("❌  REMSaveRequest does not respond to addReminderWithTitle:toReminderSubtaskContextChangeItem:")
        return
    }
    
    guard let subtaskChangeItem = saveRequest.perform(addSubtaskSel, with: title as NSString, with: subtaskContext)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create subtask change item")
        return
    }
    
    // 7. Commit the save request
    let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
    guard saveRequest.responds(to: saveSel) else {
        print("❌  REMSaveRequest does not respond to saveSynchronouslyWithError:")
        return
    }
    
    typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
        print("❌  Failed to get save method implementation")
        return
    }
    let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
    
    var saveError: NSError?
    let success = saveImp(saveRequest, saveSel, &saveError)
    
    if !success {
        print("❌  Failed to save subtask: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    // 8. Extract the created reminder's ID
    var subtaskID = "unknown"
    
    let storageSel = NSSelectorFromString("storage")
    if subtaskChangeItem.responds(to: storageSel),
       let storage = subtaskChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        let objectIDSel = NSSelectorFromString("objectID")
        if storage.responds(to: objectIDSel),
           let objectID = storage.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
            let uuidSel = NSSelectorFromString("uuid")
            if objectID.responds(to: uuidSel),
               let uuid = objectID.perform(uuidSel)?.takeUnretainedValue() as? NSUUID {
                subtaskID = uuid.uuidString
            }
        }
    }
    
    print("✅  Subtask '\(title)' created under parent \(parentID)")
    print("   Subtask ID: \(subtaskID)")
}

// --------------------------------------------------
//  Read Subtasks
// --------------------------------------------------

func readSubtasks(parentID: String) {
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    // Get subtask info from database
    let subtaskInfo = fetchSubtaskInfoFromDB()
    
    // Find all reminders with this parent
    var subtasks: [(id: String, title: String, order: Int)] = []
    
    let allReminders = ekBridge.listReminders(in: nil)
    for reminder in allReminders {
        if let info = subtaskInfo[reminder.calendarItemIdentifier],
           info.parentID == parentID {
            subtasks.append((
                id: reminder.calendarItemIdentifier,
                title: reminder.title ?? "(no title)",
                order: info.displayOrder
            ))
        }
    }
    
    subtasks.sort { $0.order < $1.order }
    
    if subtasks.isEmpty {
        print("No subtasks found for \(parentID)")
    } else {
        print("Subtasks for \(parentID):")
        for (index, subtask) in subtasks.enumerated() {
            print("[\(index)] \(subtask.title) (id:\(subtask.id))")
        }
    }
}

// --------------------------------------------------
//  Update Subtask
// --------------------------------------------------

func updateSubtask(subtaskID: String, newTitle: String? = nil, newIndex: Int? = nil) {
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard let reminder = ekBridge.reminder(withID: subtaskID) else {
        print("❌  Subtask not found: \(subtaskID)")
        return
    }
    
    // Update title using EventKit (this works for subtasks too)
    if let newTitle = newTitle {
        reminder.title = newTitle
        do {
            try ekBridge.eventStore.save(reminder, commit: true)
            print("✅  Subtask \(subtaskID) title updated to '\(newTitle)'")
        } catch {
            print("❌  Failed to update subtask: \(error.localizedDescription)")
            return
        }
    }
    
    // Updating index would require ReminderKit private APIs
    if let newIndex = newIndex {
        print("⚠️  Index update to \(newIndex) not yet supported (requires ReminderKit)")
    }
}

// --------------------------------------------------
//  Delete Subtask using ReminderKit Private APIs
// --------------------------------------------------

func deleteSubtask(subtaskID: String) {
    // Ensure ReminderKit is loaded
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
    // Get required classes
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
        print("❌  REMStore class not found")
        return
    }
    
    guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
        print("❌  REMSaveRequest class not found")
        return
    }
    
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: subtaskID) != nil else {
        print("❌  Subtask not found: \(subtaskID)")
        return
    }
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Fetch the REMReminder
    let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
    guard store.responds(to: fetchSel) else {
        print("❌  REMStore does not support fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
        return
    }
    
    typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
        print("❌  Failed to get fetch method implementation")
        return
    }
    let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
    
    var fetchError: NSError? = nil
    guard let remReminder = fetchImp(store, fetchSel, subtaskID as NSString, nil, &fetchError) as? NSObject else {
        let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
        print("❌  Failed to fetch subtask: \(errorMsg)")
        return
    }
    
    // 3. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 4. Get the change item for the reminder
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard saveRequest.responds(to: updateReminderSel),
          let changeItem = saveRequest.perform(updateReminderSel, with: remReminder)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get reminder change item")
        return
    }
    
    // 5. Call removeFromList on the change item (this deletes the reminder/subtask)
    let removeFromListSel = NSSelectorFromString("removeFromList")
    guard changeItem.responds(to: removeFromListSel) else {
        print("❌  Change item does not respond to removeFromList")
        return
    }
    _ = changeItem.perform(removeFromListSel)
    
    // 6. Commit the save request
    let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
    guard saveRequest.responds(to: saveSel) else {
        print("❌  REMSaveRequest does not respond to saveSynchronouslyWithError:")
        return
    }
    
    typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
        print("❌  Failed to get save method implementation")
        return
    }
    let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
    
    var saveError: NSError?
    let success = saveImp(saveRequest, saveSel, &saveError)
    
    if !success {
        print("❌  Failed to delete subtask: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    print("✅  Subtask \(subtaskID) deleted")
}

// --------------------------------------------------
//  Check if a reminder is in a CloudKit-synced list
// --------------------------------------------------

func checkCloudKitSync(reminderID: String) -> Bool {
    let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    let fileManager = FileManager.default
    
    guard let enumerator = fileManager.enumerator(atPath: storesPath) else { return false }
    
    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix(".sqlite") {
            let dbPath = (storesPath as NSString).appendingPathComponent(file)
            
            var db: OpaquePointer?
            if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                let query = "SELECT ZCKZONEOWNERNAME FROM ZREMCDREMINDER WHERE ZDACALENDARITEMUNIQUEIDENTIFIER = '\(reminderID)';"
                
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                    if sqlite3_step(statement) == SQLITE_ROW {
                        let zoneOwner = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                        sqlite3_finalize(statement)
                        sqlite3_close(db)
                        return zoneOwner != nil && !zoneOwner!.isEmpty
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_close(db)
            }
        }
    }
    return false
}

// --------------------------------------------------
//  CLI Dispatcher
// --------------------------------------------------

if CommandLine.arguments.count < 2 {
    print("Usage: subtaskctl <command> [options]")
    print("")
    print("Commands:")
    print("  create <parentID> <title>    Create a new subtask")
    print("  list <parentID>              List subtasks for a reminder")
    print("  update <subtaskID> [title]   Update a subtask")
    print("  delete <subtaskID>           Delete a subtask")
    print("  verify <reminderID>          Check CloudKit sync status")
    print("")
    print("Note: For subtasks to be visible in Reminders.app, the parent")
    print("      must be in an iCloud-synced list (e.g., 'To-do', not 'Reminders').")
    print("")
    if !ReminderKitBridge.isAvailable {
        print("⚠️  ReminderKit not available - some operations may fail")
    } else {
        print("✓  ReminderKit loaded successfully")
    }
    exit(0)
}

let cmd = CommandLine.arguments[1]
switch cmd {
case "create":
    guard CommandLine.arguments.count == 4 else {
        print("Usage: subtaskctl create <parentID> <title>")
        exit(1)
    }
    let parentID = CommandLine.arguments[2]
    let title    = CommandLine.arguments[3]
    
    // Check CloudKit sync status
    if !checkCloudKitSync(reminderID: parentID) {
        print("⚠️  Warning: Parent is NOT in a CloudKit-synced list.")
        print("   Subtask may not be visible in Reminders.app GUI.")
        print("   Consider moving parent to 'To-do' or another iCloud list.")
        print("")
    }
    
    createSubtask(parentID: parentID, title: title)
case "list":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: subtaskctl list <parentID>")
        exit(1)
    }
    let parentID = CommandLine.arguments[2]
    readSubtasks(parentID: parentID)
case "update":
    guard CommandLine.arguments.count >= 3 else {
        print("Usage: subtaskctl update <subtaskID> [newTitle]")
        exit(1)
    }
    let subID = CommandLine.arguments[2]
    let newTitle = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
    updateSubtask(subtaskID: subID, newTitle: newTitle)
case "delete":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: subtaskctl delete <subtaskID>")
        exit(1)
    }
    let subID = CommandLine.arguments[2]
    deleteSubtask(subtaskID: subID)
    
case "verify":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: subtaskctl verify <reminderID>")
        exit(1)
    }
    let remID = CommandLine.arguments[2]
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        exit(1)
    }
    
    if let reminder = ekBridge.reminder(withID: remID) {
        print("Reminder: \(reminder.title ?? "untitled")")
        print("  List: \(reminder.calendar?.title ?? "unknown")")
        print("  Completed: \(reminder.isCompleted)")
        
        if checkCloudKitSync(reminderID: remID) {
            print("  CloudKit Sync: ✅ Enabled")
            print("  GUI Visibility: Subtasks should appear with ▶ disclosure arrow")
        } else {
            print("  CloudKit Sync: ❌ NOT enabled")
            print("  GUI Visibility: Subtasks may NOT appear in Reminders.app")
            print("")
            print("  To fix: Move this reminder to an iCloud-synced list like 'To-do'")
        }
    } else {
        print("❌  Reminder not found: \(remID)")
    }
    
default:
    print("Unknown command: \(cmd)")
    exit(1)
}
