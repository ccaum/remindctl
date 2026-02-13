#!/usr/bin/env swift

import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge v2
//  Now with proper CloudKit sync
// --------------------------------------------------

final class ReminderKitBridge {
    private static var frameworkHandle: UnsafeMutableRawPointer?
    private static var isLoaded = false
    
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
            }
        }
        
        return isLoaded
    }
    
    static var isAvailable: Bool {
        loadFramework()
        return NSClassFromString("REMStore") != nil && NSClassFromString("REMSaveRequest") != nil
    }
}

// --------------------------------------------------
//  EventKit Store
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
//  SQLite helpers
// --------------------------------------------------

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

// --------------------------------------------------
//  Create Subtask with CloudKit Sync
// --------------------------------------------------

func createSubtaskV2(parentID: String, title: String) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
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
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    print("📍 Creating subtask '\(title)' under parent \(parentID)...")
    
    // 1. Create REMStore using initUserInteractive:
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
        print("   ✓ Store initialized (user interactive)")
    }
    
    // 2. Fetch parent REMReminder
    let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
    guard store.responds(to: fetchSel) else {
        print("❌  REMStore does not support fetch method")
        return
    }
    
    typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
        print("❌  Failed to get fetch method")
        return
    }
    let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
    
    var fetchError: NSError? = nil
    guard let parentREMReminder = fetchImp(store, fetchSel, parentID as NSString, nil, &fetchError) as? NSObject else {
        print("❌  Failed to fetch parent: \(fetchError?.localizedDescription ?? "not found")")
        return
    }
    print("   ✓ Fetched parent reminder")
    
    // 3. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
        print("   ✓ SaveRequest created with store")
    }
    
    // 4. Get change item for parent
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard saveRequest.responds(to: updateReminderSel),
          let parentChangeItem = saveRequest.perform(updateReminderSel, with: parentREMReminder)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get parent change item")
        return
    }
    print("   ✓ Got parent change item")
    
    // 5. Get subtaskContext
    let subtaskContextSel = NSSelectorFromString("subtaskContext")
    guard parentChangeItem.responds(to: subtaskContextSel),
          let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get subtask context")
        return
    }
    print("   ✓ Got subtask context")
    
    // 6. Add subtask
    let addSubtaskSel = NSSelectorFromString("addReminderWithTitle:toReminderSubtaskContextChangeItem:")
    guard saveRequest.responds(to: addSubtaskSel) else {
        print("❌  addReminderWithTitle:toReminderSubtaskContextChangeItem: not available")
        return
    }
    
    guard let subtaskChangeItem = saveRequest.perform(addSubtaskSel, with: title as NSString, with: subtaskContext)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create subtask")
        return
    }
    print("   ✓ Subtask change item created")
    
    // 7. First, save synchronously
    let saveSyncSel = NSSelectorFromString("saveSynchronouslyWithError:")
    guard saveRequest.responds(to: saveSyncSel) else {
        print("❌  saveSynchronouslyWithError: not available")
        return
    }
    
    typealias SaveSyncIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveSyncMethod = class_getInstanceMethod(type(of: saveRequest), saveSyncSel) else {
        print("❌  Failed to get save method")
        return
    }
    let saveSyncImp = unsafeBitCast(method_getImplementation(saveSyncMethod), to: SaveSyncIMP.self)
    
    var saveError: NSError?
    let saveSuccess = saveSyncImp(saveRequest, saveSyncSel, &saveError)
    
    if !saveSuccess {
        print("❌  Save failed: \(saveError?.localizedDescription ?? "unknown")")
        return
    }
    print("   ✓ Saved to local store")
    
    // 8. Now try to sync to CloudKit
    let syncToCloudKitSel = NSSelectorFromString("syncToCloudKit")
    if saveRequest.responds(to: syncToCloudKitSel) {
        _ = saveRequest.perform(syncToCloudKitSel)
        print("   ✓ CloudKit sync requested")
    }
    
    // 9. Try refreshing the parent reminder
    let refreshReminderSel = NSSelectorFromString("refreshReminder:")
    if store.responds(to: refreshReminderSel) {
        _ = store.perform(refreshReminderSel, with: parentREMReminder)
        print("   ✓ Parent reminder refreshed")
    }
    
    // 10. Extract subtask ID
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
    
    print("\n✅  Subtask created!")
    print("   Title: \(title)")
    print("   ID: \(subtaskID)")
    print("   Parent: \(parentID)")
    
    // Give the system a moment to sync
    print("\n⏳ Waiting 2 seconds for sync...")
    Thread.sleep(forTimeInterval: 2.0)
    
    // Verify via AppleScript
    print("\n🔍 Verifying via AppleScript...")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "tell application \"Reminders\" to get every reminder whose id contains \"\(subtaskID)\""]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        if output.contains(subtaskID) {
            print("   ✅ VERIFIED: Subtask visible in Reminders!")
        } else {
            print("   ⚠️  Subtask not yet visible in AppleScript query")
            print("   AppleScript output: \(output)")
        }
    } catch {
        print("   ⚠️  AppleScript verification failed: \(error)")
    }
}

// --------------------------------------------------
//  Alternative: Use Async Save with Completion
// --------------------------------------------------

func createSubtaskAsync(parentID: String, title: String) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
        print("❌  REMStore class not found")
        return
    }
    
    guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
        print("❌  REMSaveRequest class not found")
        return
    }
    
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    print("📍 Creating subtask '\(title)' via ASYNC save...")
    
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // Fetch parent
    let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
    typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else { return }
    let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
    
    var fetchError: NSError? = nil
    guard let parentREMReminder = fetchImp(store, fetchSel, parentID as NSString, nil, &fetchError) as? NSObject else {
        print("❌  Failed to fetch parent")
        return
    }
    
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard let parentChangeItem = saveRequest.perform(updateReminderSel, with: parentREMReminder)?.takeUnretainedValue() as? NSObject else {
        return
    }
    
    let subtaskContextSel = NSSelectorFromString("subtaskContext")
    guard let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
        return
    }
    
    let addSubtaskSel = NSSelectorFromString("addReminderWithTitle:toReminderSubtaskContextChangeItem:")
    guard let subtaskChangeItem = saveRequest.perform(addSubtaskSel, with: title as NSString, with: subtaskContext)?.takeUnretainedValue() as? NSObject else {
        return
    }
    
    // Try saveWithQueue:completion: instead
    let semaphore = DispatchSemaphore(value: 0)
    var asyncSaveSuccess = false
    
    let saveAsyncSel = NSSelectorFromString("saveWithQueue:completion:")
    if saveRequest.responds(to: saveAsyncSel) {
        print("   Using saveWithQueue:completion:")
        
        // Define completion block type
        typealias CompletionBlock = @convention(block) (NSError?) -> Void
        let completion: CompletionBlock = { error in
            if let error = error {
                print("   ❌ Async save error: \(error)")
            } else {
                asyncSaveSuccess = true
                print("   ✓ Async save completed!")
            }
            semaphore.signal()
        }
        
        // Get the method implementation
        typealias SaveAsyncIMP = @convention(c) (AnyObject, Selector, DispatchQueue, AnyObject) -> Void
        guard let saveAsyncMethod = class_getInstanceMethod(type(of: saveRequest), saveAsyncSel) else {
            print("   ❌ Could not get saveWithQueue:completion: method")
            return
        }
        let saveAsyncImp = unsafeBitCast(method_getImplementation(saveAsyncMethod), to: SaveAsyncIMP.self)
        
        // Call with main queue and our completion block
        saveAsyncImp(saveRequest, saveAsyncSel, DispatchQueue.main, completion as AnyObject)
        
        // Run the runloop for the completion to fire
        let timeout = DispatchTime.now() + .seconds(10)
        var runLoopDeadline = Date(timeIntervalSinceNow: 10)
        
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            if Date() > runLoopDeadline {
                print("   ⚠️  Async save timeout")
                break
            }
        }
    } else {
        // Fall back to sync save
        print("   saveWithQueue:completion: not available, using sync save")
        let saveSyncSel = NSSelectorFromString("saveSynchronouslyWithError:")
        typealias SaveSyncIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        guard let saveSyncMethod = class_getInstanceMethod(type(of: saveRequest), saveSyncSel) else { return }
        let saveSyncImp = unsafeBitCast(method_getImplementation(saveSyncMethod), to: SaveSyncIMP.self)
        
        var saveError: NSError?
        asyncSaveSuccess = saveSyncImp(saveRequest, saveSyncSel, &saveError)
    }
    
    // Extract ID
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
    
    if asyncSaveSuccess {
        print("\n✅  Subtask created (async): \(title)")
        print("   ID: \(subtaskID)")
    }
}

// --------------------------------------------------
//  List Subtasks
// --------------------------------------------------

func listSubtasks(parentID: String) {
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    let subtaskInfo = fetchSubtaskInfoFromDB()
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
//  CLI
// --------------------------------------------------

if CommandLine.arguments.count < 2 {
    print("Usage: subtaskctl_v2 <command> [options]")
    print("")
    print("Commands:")
    print("  create <parentID> <title>    Create a new subtask (with CloudKit sync)")
    print("  create-async <parentID> <title>  Create using async save")
    print("  list <parentID>              List subtasks")
    print("")
    if !ReminderKitBridge.isAvailable {
        print("⚠️  ReminderKit not available")
    } else {
        print("✓  ReminderKit loaded")
    }
    exit(0)
}

let cmd = CommandLine.arguments[1]
switch cmd {
case "create":
    guard CommandLine.arguments.count == 4 else {
        print("Usage: subtaskctl_v2 create <parentID> <title>")
        exit(1)
    }
    createSubtaskV2(parentID: CommandLine.arguments[2], title: CommandLine.arguments[3])
    
case "create-async":
    guard CommandLine.arguments.count == 4 else {
        print("Usage: subtaskctl_v2 create-async <parentID> <title>")
        exit(1)
    }
    createSubtaskAsync(parentID: CommandLine.arguments[2], title: CommandLine.arguments[3])
    
case "list":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: subtaskctl_v2 list <parentID>")
        exit(1)
    }
    listSubtasks(parentID: CommandLine.arguments[2])
    
default:
    print("Unknown command: \(cmd)")
    exit(1)
}
