#!/usr/bin/env swift

import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge for Creating Reminders in Sections
//  Uses dlopen + NSClassFromString to interact with
//  Apple's private ReminderKit.framework
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
        return NSClassFromString("REMSaveRequest") != nil && NSClassFromString("REMStore") != nil
    }
}

// --------------------------------------------------
//  EventKit Store for basic access & verification
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
    
    func calendars() -> [EKCalendar] {
        return eventStore.calendars(for: .reminder)
    }
    
    func calendar(withTitle title: String) -> EKCalendar? {
        return eventStore.calendars(for: .reminder).first { $0.title == title }
    }
}

// --------------------------------------------------
//  SQLite Database Access
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

@_silgen_name("sqlite3_column_blob")
func sqlite3_column_blob(_ stmt: OpaquePointer?, _ iCol: Int32) -> UnsafeRawPointer?

@_silgen_name("sqlite3_column_bytes")
func sqlite3_column_bytes(_ stmt: OpaquePointer?, _ iCol: Int32) -> Int32

let SQLITE_OK: Int32 = 0
let SQLITE_ROW: Int32 = 100
let SQLITE_OPEN_READONLY: Int32 = 1

struct ListInfo {
    let name: String
    let identifier: UUID
    let isCloudKitSynced: Bool
    let dbPath: String
}

struct SectionInfo {
    let displayName: String
    let identifier: UUID
    let listIdentifier: UUID
    let dbPath: String
}

func findDatabasePaths() -> [String] {
    var paths: [String] = []
    let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    let fileManager = FileManager.default
    
    guard let enumerator = fileManager.enumerator(atPath: storesPath) else { return paths }
    
    while let file = enumerator.nextObject() as? String {
        if file.hasSuffix(".sqlite") {
            let dbPath = (storesPath as NSString).appendingPathComponent(file)
            paths.append(dbPath)
        }
    }
    return paths
}

func fetchListsFromDB() -> [ListInfo] {
    var results: [ListInfo] = []
    
    for dbPath in findDatabasePaths() {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            let query = """
            SELECT ZNAME, ZIDENTIFIER, ZCKZONEOWNERNAME
            FROM ZREMCDBASELIST
            WHERE (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL)
              AND ZNAME IS NOT NULL
              AND ZNAME != 'SiriFoundInApps';
            """
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
                    let name = String(cString: namePtr)
                    
                    guard let identifierBlob = sqlite3_column_blob(statement, 1) else { continue }
                    let identifierBytes = sqlite3_column_bytes(statement, 1)
                    guard identifierBytes == 16 else { continue }
                    
                    let uuid = identifierBlob.bindMemory(to: uuid_t.self, capacity: 1).pointee
                    let identifier = UUID(uuid: uuid)
                    
                    let zoneOwner = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    let isCloudKitSynced = zoneOwner != nil && !zoneOwner!.isEmpty
                    
                    results.append(ListInfo(
                        name: name,
                        identifier: identifier,
                        isCloudKitSynced: isCloudKitSynced,
                        dbPath: dbPath
                    ))
                }
                _ = sqlite3_finalize(statement)
            }
            _ = sqlite3_close(db)
        }
    }
    return results
}

func fetchSectionsFromDB(listIdentifier: UUID? = nil) -> [SectionInfo] {
    var results: [SectionInfo] = []
    
    for dbPath in findDatabasePaths() {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var query = """
            SELECT s.ZDISPLAYNAME, s.ZIDENTIFIER, l.ZIDENTIFIER
            FROM ZREMCDBASESECTION s
            JOIN ZREMCDBASELIST l ON s.ZLIST = l.Z_PK
            WHERE (s.ZMARKEDFORDELETION = 0 OR s.ZMARKEDFORDELETION IS NULL)
            """
            if let listID = listIdentifier {
                query += " AND l.ZIDENTIFIER = x'\(listID.uuidString.replacingOccurrences(of: "-", with: ""))'"
            }
            
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let namePtr = sqlite3_column_text(statement, 0) else { continue }
                    let displayName = String(cString: namePtr)
                    
                    guard let sectionIdBlob = sqlite3_column_blob(statement, 1) else { continue }
                    let sectionIdBytes = sqlite3_column_bytes(statement, 1)
                    guard sectionIdBytes == 16 else { continue }
                    let sectionUuid = sectionIdBlob.bindMemory(to: uuid_t.self, capacity: 1).pointee
                    let sectionIdentifier = UUID(uuid: sectionUuid)
                    
                    guard let listIdBlob = sqlite3_column_blob(statement, 2) else { continue }
                    let listIdBytes = sqlite3_column_bytes(statement, 2)
                    guard listIdBytes == 16 else { continue }
                    let listUuid = listIdBlob.bindMemory(to: uuid_t.self, capacity: 1).pointee
                    let listIdentifier = UUID(uuid: listUuid)
                    
                    results.append(SectionInfo(
                        displayName: displayName,
                        identifier: sectionIdentifier,
                        listIdentifier: listIdentifier,
                        dbPath: dbPath
                    ))
                }
                _ = sqlite3_finalize(statement)
            }
            _ = sqlite3_close(db)
        }
    }
    return results
}

func findList(byName name: String) -> ListInfo? {
    return fetchListsFromDB().first { $0.name.lowercased() == name.lowercased() }
}

func findList(byID id: String) -> ListInfo? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return fetchListsFromDB().first { $0.identifier == uuid }
}

func findSection(byID id: String) -> SectionInfo? {
    guard let uuid = UUID(uuidString: id) else { return nil }
    return fetchSectionsFromDB().first { $0.identifier == uuid }
}

func findSection(byName name: String, inList listID: String? = nil) -> SectionInfo? {
    let sections: [SectionInfo]
    if let listID = listID {
        if let uuid = UUID(uuidString: listID) {
            sections = fetchSectionsFromDB(listIdentifier: uuid)
        } else if let list = findList(byName: listID) {
            sections = fetchSectionsFromDB(listIdentifier: list.identifier)
        } else {
            return nil
        }
    } else {
        sections = fetchSectionsFromDB()
    }
    return sections.first { $0.displayName.lowercased() == name.lowercased() }
}

// --------------------------------------------------
//  Create Reminder in Section using ReminderKit Private APIs
// --------------------------------------------------

func createReminderInSection(sectionIdentifier: String, title: String, notes: String? = nil) {
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
    
    guard let listClass = NSClassFromString("REMList") as? NSObject.Type else {
        print("❌  REMList class not found")
        return
    }
    
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    // Find section info - support both UUID and name
    var sectionInfo: SectionInfo?
    if let _ = UUID(uuidString: sectionIdentifier) {
        sectionInfo = findSection(byID: sectionIdentifier)
    } else {
        sectionInfo = findSection(byName: sectionIdentifier)
    }
    
    guard let section = sectionInfo else {
        print("❌  Section not found: \(sectionIdentifier)")
        return
    }
    
    let listUUID = section.listIdentifier
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Create list objectID and fetch the list
    let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
    guard listClass.responds(to: objectIDWithUUIDSel) else {
        print("❌  REMList does not respond to objectIDWithUUID:")
        return
    }
    guard let listObjectID = listClass.perform(objectIDWithUUIDSel, with: NSUUID(uuidString: listUUID.uuidString))?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create list objectID")
        return
    }
    
    let fetchListSel = NSSelectorFromString("fetchListWithObjectID:error:")
    guard store.responds(to: fetchListSel) else {
        print("❌  REMStore does not support fetchListWithObjectID:error:")
        return
    }
    
    typealias FetchListIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchListMethod = class_getInstanceMethod(type(of: store), fetchListSel) else {
        print("❌  Failed to get fetch list method implementation")
        return
    }
    let fetchListImp = unsafeBitCast(method_getImplementation(fetchListMethod), to: FetchListIMP.self)
    
    var fetchError: NSError? = nil
    guard let remList = fetchListImp(store, fetchListSel, listObjectID, &fetchError) as? NSObject else {
        let errorMsg = fetchError?.localizedDescription ?? "List not found"
        print("❌  Failed to fetch list: \(errorMsg)")
        return
    }
    
    // 3. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 4. Get list change item
    let updateListSel = NSSelectorFromString("updateList:")
    guard saveRequest.responds(to: updateListSel),
          let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get list change item")
        return
    }
    
    // 5. Create new reminder
    let addReminderSel = NSSelectorFromString("addReminderWithTitle:toListChangeItem:")
    guard saveRequest.responds(to: addReminderSel) else {
        print("❌  REMSaveRequest does not respond to addReminderWithTitle:toListChangeItem:")
        return
    }
    
    guard let reminderChangeItem = saveRequest.perform(addReminderSel, with: title as NSString, with: listChangeItem)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create reminder change item")
        return
    }
    
    // 6. Set notes on the reminder (via change item, not storage) and get reminder ID
    let storageSel = NSSelectorFromString("storage")
    var reminderID = "unknown"
    if reminderChangeItem.responds(to: storageSel),
       let storage = reminderChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        // Get reminder UUID from storage
        let objectIDSel = NSSelectorFromString("objectID")
        if storage.responds(to: objectIDSel),
           let objID = storage.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
            let uuidSel = NSSelectorFromString("uuid")
            if objID.responds(to: uuidSel),
               let uuid = objID.perform(uuidSel)?.takeUnretainedValue() as? NSUUID {
                reminderID = uuid.uuidString
            }
        }
    }
    
    // Set notes on the reminderChangeItem directly (not on storage)
    let setNotesSel = NSSelectorFromString("setNotesAsString:")
    if reminderChangeItem.responds(to: setNotesSel) {
        var noteContent = notes ?? ""
        // Add section marker to help with manual organization
        let sectionMarker = "[Section: \(section.displayName)]"
        if !noteContent.isEmpty {
            noteContent = sectionMarker + "\n\n" + noteContent
        } else {
            noteContent = sectionMarker
        }
        _ = reminderChangeItem.perform(setNotesSel, with: noteContent as NSString)
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
        print("❌  Failed to save: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    // Get list name for output
    var listName = "unknown"
    if let list = fetchListsFromDB().first(where: { $0.identifier == listUUID }) {
        listName = list.name
    }
    
    print("✅  Reminder '\(title)' created")
    print("   Reminder ID: \(reminderID)")
    print("   List: \(listName)")
    print("   Target Section: \(section.displayName)")
    print("")
    print("⚠️  NOTE: Due to macOS limitations, automatic section assignment is not")
    print("   currently supported. The reminder has been created in the list with")
    print("   a note marker indicating its intended section.")
    print("")
    print("   To complete the organization:")
    print("   1. Open Reminders.app")
    print("   2. Navigate to '\(listName)' > '\(section.displayName)'")
    print("   3. Drag the reminder into the section, or use the note as reference")
}

// --------------------------------------------------
//  Create Reminder in List (without section)
// --------------------------------------------------

func createReminderInList(listIdentifier: String, title: String) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type,
          let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type,
          let listClass = NSClassFromString("REMList") as? NSObject.Type else {
        print("❌  Required classes not found")
        return
    }
    
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    // Resolve list identifier
    var listUUID: UUID
    if let uuid = UUID(uuidString: listIdentifier) {
        listUUID = uuid
    } else if let list = findList(byName: listIdentifier) {
        listUUID = list.identifier
    } else {
        print("❌  List not found: \(listIdentifier)")
        return
    }
    
    // Create store
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // Fetch list
    let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
    guard let listObjectID = listClass.perform(objectIDWithUUIDSel, with: NSUUID(uuidString: listUUID.uuidString))?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create list objectID")
        return
    }
    
    let fetchListSel = NSSelectorFromString("fetchListWithObjectID:error:")
    typealias FetchListIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchListMethod = class_getInstanceMethod(type(of: store), fetchListSel) else {
        print("❌  Failed to get fetch list method")
        return
    }
    let fetchListImp = unsafeBitCast(method_getImplementation(fetchListMethod), to: FetchListIMP.self)
    
    var fetchError: NSError? = nil
    guard let remList = fetchListImp(store, fetchListSel, listObjectID, &fetchError) as? NSObject else {
        print("❌  Failed to fetch list: \(fetchError?.localizedDescription ?? "unknown")")
        return
    }
    
    // Create save request
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // Get list change item
    let updateListSel = NSSelectorFromString("updateList:")
    guard let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get list change item")
        return
    }
    
    // Create reminder
    let addReminderSel = NSSelectorFromString("addReminderWithTitle:toListChangeItem:")
    guard let reminderChangeItem = saveRequest.perform(addReminderSel, with: title as NSString, with: listChangeItem)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create reminder")
        return
    }
    
    // Save
    let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
    typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
        print("❌  Failed to get save method")
        return
    }
    let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
    
    var saveError: NSError?
    let success = saveImp(saveRequest, saveSel, &saveError)
    
    if !success {
        print("❌  Failed to save: \(saveError?.localizedDescription ?? "unknown")")
        return
    }
    
    // Get reminder ID
    var reminderID = "unknown"
    let storageSel = NSSelectorFromString("storage")
    if reminderChangeItem.responds(to: storageSel),
       let storage = reminderChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        let objectIDSel = NSSelectorFromString("objectID")
        if storage.responds(to: objectIDSel),
           let objID = storage.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
            let uuidSel = NSSelectorFromString("uuid")
            if objID.responds(to: uuidSel),
               let uuid = objID.perform(uuidSel)?.takeUnretainedValue() as? NSUUID {
                reminderID = uuid.uuidString
            }
        }
    }
    
    print("✅  Reminder '\(title)' created in list \(listIdentifier)")
    print("   Reminder ID: \(reminderID)")
}

// --------------------------------------------------
//  List Available Lists
// --------------------------------------------------

func listAvailableLists() {
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    let lists = fetchListsFromDB()
    
    if lists.isEmpty {
        print("No reminder lists found")
    } else {
        print("Available lists:")
        for list in lists {
            let syncStatus = list.isCloudKitSynced ? "✅ iCloud" : "⚠️  local"
            print("  - \(list.name) [\(syncStatus)] (id:\(list.identifier.uuidString))")
        }
    }
}

// --------------------------------------------------
//  List Sections
// --------------------------------------------------

func listSections(listIdentifier: String?) {
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    var listUUID: UUID? = nil
    if let listID = listIdentifier {
        if let uuid = UUID(uuidString: listID) {
            listUUID = uuid
        } else if let list = findList(byName: listID) {
            listUUID = list.identifier
        } else {
            print("❌  List not found: \(listID)")
            return
        }
    }
    
    let sections = fetchSectionsFromDB(listIdentifier: listUUID)
    
    if sections.isEmpty {
        if let listID = listIdentifier {
            print("No sections found in list \(listID)")
        } else {
            print("No sections found")
        }
    } else {
        print("Sections:")
        for (index, section) in sections.enumerated() {
            print("[\(index)] \(section.displayName) (id:\(section.identifier.uuidString), list:\(section.listIdentifier.uuidString))")
        }
    }
}

// --------------------------------------------------
//  CLI Dispatcher
// --------------------------------------------------

if CommandLine.arguments.count < 2 {
    print("Usage: reminderctl <command> [options]")
    print("")
    print("Commands:")
    print("  add <title> --list <listID|listName>                Create reminder in a list")
    print("  add <title> --section <sectionID|sectionName>       Create reminder in a section")
    print("  lists                                               Show available lists")
    print("  sections [listID|listName]                          Show sections")
    print("")
    print("Examples:")
    print("  reminderctl add \"Buy groceries\" --list \"To-do\"")
    print("  reminderctl add \"Task in section\" --section \"My Section\"")
    print("  reminderctl add \"Task\" --section \"12345678-1234-1234-1234-123456789012\"")
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
case "add":
    // Parse arguments
    var title: String?
    var listID: String?
    var sectionID: String?
    
    var i = 2
    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        if arg == "--list" && i + 1 < CommandLine.arguments.count {
            listID = CommandLine.arguments[i + 1]
            i += 2
        } else if arg == "--section" && i + 1 < CommandLine.arguments.count {
            sectionID = CommandLine.arguments[i + 1]
            i += 2
        } else if title == nil {
            title = arg
            i += 1
        } else {
            i += 1
        }
    }
    
    guard let reminderTitle = title else {
        print("Usage: reminderctl add <title> --list <listID> | --section <sectionID>")
        exit(1)
    }
    
    if let sectionID = sectionID {
        createReminderInSection(sectionIdentifier: sectionID, title: reminderTitle)
    } else if let listID = listID {
        createReminderInList(listIdentifier: listID, title: reminderTitle)
    } else {
        print("Error: Either --list or --section must be specified")
        exit(1)
    }
    
case "lists":
    listAvailableLists()
    
case "sections":
    let listID = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    listSections(listIdentifier: listID)
    
default:
    print("Unknown command: \(cmd)")
    exit(1)
}
