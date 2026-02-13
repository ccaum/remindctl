#!/usr/bin/env swift

import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge for Creating Reminders with Section Assignment
//  Uses REMMemberships class for proper section assignment (discovered working method)
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
        return NSClassFromString("REMSaveRequest") != nil && 
               NSClassFromString("REMStore") != nil &&
               NSClassFromString("REMMemberships") != nil
    }
}

// --------------------------------------------------
//  EventKit Store for basic access
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
//  Create Reminder with Section Assignment (WORKING METHOD)
// --------------------------------------------------

func createReminderInSection(sectionIdentifier: String, title: String, notes: String? = nil) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit framework not available")
        return
    }
    
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type,
          let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type,
          let listClass = NSClassFromString("REMList") as? NSObject.Type,
          let membershipClass = NSClassFromString("REMMembership") as? NSObject.Type,
          let membershipsClass = NSClassFromString("REMMemberships") as? NSObject.Type else {
        print("❌  Required ReminderKit classes not found")
        return
    }
    
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    // Find section info
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
    let sectionUUID = section.identifier
    
    // Get list name for output
    var listName = "unknown"
    if let list = fetchListsFromDB().first(where: { $0.identifier == listUUID }) {
        listName = list.name
    }
    
    // 1. Create REMStore
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
    
    // 3. Create REMSaveRequest
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
    
    // 5. Create the reminder
    let addReminderSel = NSSelectorFromString("addReminderWithTitle:toListChangeItem:")
    guard saveRequest.responds(to: addReminderSel),
          let reminderChangeItem = saveRequest.perform(addReminderSel, with: title as NSString, with: listChangeItem)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create reminder")
        return
    }
    
    // 6. Set notes if provided
    if let notesText = notes {
        let setNotesSel = NSSelectorFromString("setNotesAsString:")
        if reminderChangeItem.responds(to: setNotesSel) {
            _ = reminderChangeItem.perform(setNotesSel, with: notesText as NSString)
        }
    }
    
    // 7. Get reminder UUID from storage
    var reminderUUID: NSUUID? = nil
    let storageSel = NSSelectorFromString("storage")
    if reminderChangeItem.responds(to: storageSel),
       let storage = reminderChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        let objectIDSel = NSSelectorFromString("objectID")
        if storage.responds(to: objectIDSel),
           let objID = storage.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
            let uuidSel = NSSelectorFromString("uuid")
            if objID.responds(to: uuidSel),
               let uuid = objID.perform(uuidSel)?.takeUnretainedValue() as? NSUUID {
                reminderUUID = uuid
            }
        }
    }
    
    guard let remUUID = reminderUUID else {
        print("❌  Failed to get reminder UUID")
        return
    }
    
    // 8. Get sectionsContextChangeItem
    let sectionsContextSel = NSSelectorFromString("sectionsContextChangeItem")
    guard listChangeItem.responds(to: sectionsContextSel),
          let sectionsContextChangeItem = listChangeItem.perform(sectionsContextSel)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get sections context change item")
        return
    }
    
    // 9. Create REMMembership object
    let sectionNSUUID = NSUUID(uuidString: sectionUUID.uuidString)!
    let now = Date()
    
    let initMembershipSel = NSSelectorFromString("initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:")
    let membershipInstance = membershipClass.init()
    
    typealias InitMembershipIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Bool, AnyObject) -> AnyObject?
    guard let initMembershipMethod = class_getInstanceMethod(membershipClass, initMembershipSel) else {
        print("❌  Failed to get membership init method")
        return
    }
    let initMembershipImp = unsafeBitCast(method_getImplementation(initMembershipMethod), to: InitMembershipIMP.self)
    
    guard let membership = initMembershipImp(membershipInstance, initMembershipSel, remUUID, sectionNSUUID, false, now as NSDate) as? NSObject else {
        print("❌  Failed to create membership")
        return
    }
    
    // 10. Create REMMemberships object (KEY: use this wrapper class, not plain NSSet)
    let membershipsSet = NSSet(object: membership)
    let initWithMembershipsSel = NSSelectorFromString("initWithMemberships:")
    
    let membershipsInstance = membershipsClass.init()
    guard membershipsInstance.responds(to: initWithMembershipsSel),
          let memberships = membershipsInstance.perform(initWithMembershipsSel, with: membershipsSet)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create REMMemberships object")
        return
    }
    
    // 11. Set the unsaved memberships
    let setMembershipsSel = NSSelectorFromString("setUnsavedMembershipsOfRemindersInSections:")
    if sectionsContextChangeItem.responds(to: setMembershipsSel) {
        _ = sectionsContextChangeItem.perform(setMembershipsSel, with: memberships)
    } else {
        print("❌  Failed to set memberships")
        return
    }
    
    // 12. Save
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
    
    print("✅  Reminder '\(title)' created in section '\(section.displayName)'")
    print("   Reminder ID: \(remUUID.uuidString)")
    print("   List: \(listName)")
    print("   Section: \(section.displayName) (\(section.identifier))")
}

// --------------------------------------------------
//  Create Reminder in List (without section)
// --------------------------------------------------

func createReminderInList(listIdentifier: String, title: String, notes: String? = nil) {
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
    
    var listUUID: UUID
    if let uuid = UUID(uuidString: listIdentifier) {
        listUUID = uuid
    } else if let list = findList(byName: listIdentifier) {
        listUUID = list.identifier
    } else {
        print("❌  List not found: \(listIdentifier)")
        return
    }
    
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
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
    
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    let updateListSel = NSSelectorFromString("updateList:")
    guard let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get list change item")
        return
    }
    
    let addReminderSel = NSSelectorFromString("addReminderWithTitle:toListChangeItem:")
    guard let reminderChangeItem = saveRequest.perform(addReminderSel, with: title as NSString, with: listChangeItem)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create reminder")
        return
    }
    
    if let notesText = notes {
        let setNotesSel = NSSelectorFromString("setNotesAsString:")
        if reminderChangeItem.responds(to: setNotesSel) {
            _ = reminderChangeItem.perform(setNotesSel, with: notesText as NSString)
        }
    }
    
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
    print("  add <title> --section <sectionID|sectionName>       Create reminder in a section ✅")
    print("  lists                                               Show available lists")
    print("  sections [listID|listName]                          Show sections")
    print("")
    print("Examples:")
    print("  reminderctl add \"Buy groceries\" --list \"To-do\"")
    print("  reminderctl add \"Task in section\" --section \"Misc\"")
    print("  reminderctl add \"Task\" --section \"EC2FA675-4B05-4022-A22C-2DB61D827B8A\"")
    print("")
    print("Note: Section assignment is now fully supported! Reminders will appear")
    print("      directly under the specified section in Reminders.app.")
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
    var title: String?
    var listID: String?
    var sectionID: String?
    var notes: String?
    
    var i = 2
    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        if arg == "--list" && i + 1 < CommandLine.arguments.count {
            listID = CommandLine.arguments[i + 1]
            i += 2
        } else if arg == "--section" && i + 1 < CommandLine.arguments.count {
            sectionID = CommandLine.arguments[i + 1]
            i += 2
        } else if arg == "--notes" && i + 1 < CommandLine.arguments.count {
            notes = CommandLine.arguments[i + 1]
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
        createReminderInSection(sectionIdentifier: sectionID, title: reminderTitle, notes: notes)
    } else if let listID = listID {
        createReminderInList(listIdentifier: listID, title: reminderTitle, notes: notes)
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
