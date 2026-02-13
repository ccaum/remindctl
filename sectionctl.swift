#!/usr/bin/env swift

import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge for Sections
//  Uses dlopen + NSClassFromString to interact with
//  Apple's private ReminderKit.framework for sections
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
            }
        }
        
        return isLoaded
    }
    
    /// Check if ReminderKit classes are available
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
//  SQLite Database Access for List ObjectIDs
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
                    
                    // Get identifier as blob (16 bytes for UUID)
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
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
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
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
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

// --------------------------------------------------
//  Create Section using ReminderKit Private APIs
// --------------------------------------------------

func createSection(listIdentifier: String, displayName: String) {
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
    
    // Request EventKit access (needed for permission)
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    // Parse the list identifier
    guard let listUUID = UUID(uuidString: listIdentifier) else {
        // Maybe it's a list name?
        if let list = findList(byName: listIdentifier) {
            createSection(listIdentifier: list.identifier.uuidString, displayName: displayName)
            return
        }
        print("❌  Invalid list identifier: \(listIdentifier)")
        return
    }
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Create REMListObjectID using REMList.objectIDWithUUID:
    let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
    guard listClass.responds(to: objectIDWithUUIDSel) else {
        print("❌  REMList does not respond to objectIDWithUUID:")
        return
    }
    guard let listObjectID = listClass.perform(objectIDWithUUIDSel, with: NSUUID(uuidString: listUUID.uuidString))?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create list objectID")
        return
    }
    
    // 3. Fetch the REMList using the objectID
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
    
    print("✓  Fetched list")
    
    // 4. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 5. Get list change item using updateList:
    let updateListSel = NSSelectorFromString("updateList:")
    guard saveRequest.responds(to: updateListSel),
          let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get list change item")
        return
    }
    
    print("✓  Got list change item")
    
    // 6. Get sectionsContextChangeItem from the list change item
    let sectionsContextSel = NSSelectorFromString("sectionsContextChangeItem")
    guard listChangeItem.responds(to: sectionsContextSel),
          let sectionsContext = listChangeItem.perform(sectionsContextSel)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get sections context from list change item")
        return
    }
    
    print("✓  Got sections context")
    
    // 7. Use addListSectionWithDisplayName:toListSectionContextChangeItem: to create the section
    let addSectionSel = NSSelectorFromString("addListSectionWithDisplayName:toListSectionContextChangeItem:")
    guard saveRequest.responds(to: addSectionSel) else {
        print("❌  REMSaveRequest does not respond to addListSectionWithDisplayName:toListSectionContextChangeItem:")
        return
    }
    
    guard let sectionChangeItem = saveRequest.perform(addSectionSel, with: displayName as NSString, with: sectionsContext)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create section change item")
        return
    }
    
    print("✓  Created section change item")
    
    // 8. Commit the save request
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
        print("❌  Failed to save section: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    // 9. Extract the created section's ID
    var sectionID = "unknown"
    
    let storageSel = NSSelectorFromString("storage")
    if sectionChangeItem.responds(to: storageSel),
       let storage = sectionChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        let objectIDSel = NSSelectorFromString("objectID")
        if storage.responds(to: objectIDSel),
           let objectID = storage.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
            let uuidSel = NSSelectorFromString("uuid")
            if objectID.responds(to: uuidSel),
               let uuid = objectID.perform(uuidSel)?.takeUnretainedValue() as? NSUUID {
                sectionID = uuid.uuidString
            }
        }
    }
    
    print("✅  Section '\(displayName)' created in list \(listIdentifier)")
    print("   Section ID: \(sectionID)")
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
//  Delete Section using ReminderKit Private APIs
// --------------------------------------------------

func deleteSection(sectionIdentifier: String) {
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
    
    guard let listSectionClass = NSClassFromString("REMListSection") as? NSObject.Type else {
        print("❌  REMListSection class not found")
        return
    }
    
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard let sectionUUID = UUID(uuidString: sectionIdentifier) else {
        print("❌  Invalid section identifier: \(sectionIdentifier)")
        return
    }
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Create REMListSectionObjectID using REMListSection.objectIDWithUUID:
    let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
    guard listSectionClass.responds(to: objectIDWithUUIDSel) else {
        print("❌  REMListSection does not respond to objectIDWithUUID:")
        return
    }
    guard let sectionObjectID = listSectionClass.perform(objectIDWithUUIDSel, with: NSUUID(uuidString: sectionUUID.uuidString))?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create section objectID")
        return
    }
    
    // 3. Fetch the REMListSection using the objectID
    let fetchSectionSel = NSSelectorFromString("fetchListSectionWithObjectID:error:")
    guard store.responds(to: fetchSectionSel) else {
        print("❌  REMStore does not support fetchListSectionWithObjectID:error:")
        return
    }
    
    typealias FetchSectionIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchSectionMethod = class_getInstanceMethod(type(of: store), fetchSectionSel) else {
        print("❌  Failed to get fetch section method implementation")
        return
    }
    let fetchSectionImp = unsafeBitCast(method_getImplementation(fetchSectionMethod), to: FetchSectionIMP.self)
    
    var fetchError: NSError? = nil
    guard let remSection = fetchSectionImp(store, fetchSectionSel, sectionObjectID, &fetchError) as? NSObject else {
        let errorMsg = fetchError?.localizedDescription ?? "Section not found"
        print("❌  Failed to fetch section: \(errorMsg)")
        return
    }
    
    print("✓  Fetched section")
    
    // 4. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 5. Get section change item using updateListSection:
    let updateSectionSel = NSSelectorFromString("updateListSection:")
    guard saveRequest.responds(to: updateSectionSel),
          let sectionChangeItem = saveRequest.perform(updateSectionSel, with: remSection)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get section change item")
        return
    }
    
    print("✓  Got section change item")
    
    // 6. Call removeFromList on the change item
    let removeFromListSel = NSSelectorFromString("removeFromList")
    guard sectionChangeItem.responds(to: removeFromListSel) else {
        print("❌  Section change item does not respond to removeFromList")
        return
    }
    _ = sectionChangeItem.perform(removeFromListSel)
    
    print("✓  Marked section for deletion")
    
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
        print("❌  Failed to delete section: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    print("✅  Section \(sectionIdentifier) deleted")
}

// --------------------------------------------------
//  Update Section using ReminderKit Private APIs
// --------------------------------------------------

func updateSection(sectionIdentifier: String, newDisplayName: String) {
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
    
    guard let listSectionClass = NSClassFromString("REMListSection") as? NSObject.Type else {
        print("❌  REMListSection class not found")
        return
    }
    
    // Request EventKit access
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard let sectionUUID = UUID(uuidString: sectionIdentifier) else {
        print("❌  Invalid section identifier: \(sectionIdentifier)")
        return
    }
    
    // 1. Create REMStore with user interactive mode
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // 2. Create REMListSectionObjectID using REMListSection.objectIDWithUUID:
    let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
    guard listSectionClass.responds(to: objectIDWithUUIDSel) else {
        print("❌  REMListSection does not respond to objectIDWithUUID:")
        return
    }
    guard let sectionObjectID = listSectionClass.perform(objectIDWithUUIDSel, with: NSUUID(uuidString: sectionUUID.uuidString))?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to create section objectID")
        return
    }
    
    // 3. Fetch the REMListSection using the objectID
    let fetchSectionSel = NSSelectorFromString("fetchListSectionWithObjectID:error:")
    guard store.responds(to: fetchSectionSel) else {
        print("❌  REMStore does not support fetchListSectionWithObjectID:error:")
        return
    }
    
    typealias FetchSectionIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchSectionMethod = class_getInstanceMethod(type(of: store), fetchSectionSel) else {
        print("❌  Failed to get fetch section method implementation")
        return
    }
    let fetchSectionImp = unsafeBitCast(method_getImplementation(fetchSectionMethod), to: FetchSectionIMP.self)
    
    var fetchError: NSError? = nil
    guard let remSection = fetchSectionImp(store, fetchSectionSel, sectionObjectID, &fetchError) as? NSObject else {
        let errorMsg = fetchError?.localizedDescription ?? "Section not found"
        print("❌  Failed to fetch section: \(errorMsg)")
        return
    }
    
    print("✓  Fetched section")
    
    // 4. Create REMSaveRequest with store
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // 5. Get section change item using updateListSection:
    let updateSectionSel = NSSelectorFromString("updateListSection:")
    guard saveRequest.responds(to: updateSectionSel),
          let sectionChangeItem = saveRequest.perform(updateSectionSel, with: remSection)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get section change item")
        return
    }
    
    print("✓  Got section change item")
    
    // 6. Update the displayName using storage
    let storageSel = NSSelectorFromString("storage")
    if sectionChangeItem.responds(to: storageSel),
       let storage = sectionChangeItem.perform(storageSel)?.takeUnretainedValue() as? NSObject {
        let setDisplayNameSel = NSSelectorFromString("setDisplayName:")
        if storage.responds(to: setDisplayNameSel) {
            _ = storage.perform(setDisplayNameSel, with: newDisplayName as NSString)
            print("✓  Updated displayName via storage")
        } else {
            // Try setValue:forKey:
            storage.setValue(newDisplayName, forKey: "displayName")
            print("✓  Updated displayName via KVC")
        }
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
        print("❌  Failed to update section: \(saveError?.localizedDescription ?? "unknown error")")
        return
    }
    
    print("✅  Section \(sectionIdentifier) updated to '\(newDisplayName)'")
}

// --------------------------------------------------
//  List available reminder lists
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
        print("\nNote: For sections to sync properly, use iCloud-synced lists.")
    }
}

// --------------------------------------------------
//  CLI Dispatcher
// --------------------------------------------------

if CommandLine.arguments.count < 2 {
    print("Usage: sectionctl <command> [options]")
    print("")
    print("Commands:")
    print("  create <listID|listName> <displayName>  Create a new section in a list")
    print("  list [listID|listName]                  List sections (optionally for a specific list)")
    print("  update <sectionID> <newDisplayName>     Update a section's display name")
    print("  delete <sectionID>                      Delete a section")
    print("  lists                                   Show available reminder lists")
    print("")
    print("Examples:")
    print("  sectionctl create \"To-do\" \"My Section\"")
    print("  sectionctl list \"To-do\"")
    print("  sectionctl update 12345678-1234-1234-1234-123456789012 \"New Name\"")
    print("  sectionctl delete 12345678-1234-1234-1234-123456789012")
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
        print("Usage: sectionctl create <listID|listName> <displayName>")
        exit(1)
    }
    let listID = CommandLine.arguments[2]
    let displayName = CommandLine.arguments[3]
    createSection(listIdentifier: listID, displayName: displayName)
    
case "list":
    let listID = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
    listSections(listIdentifier: listID)
    
case "update":
    guard CommandLine.arguments.count == 4 else {
        print("Usage: sectionctl update <sectionID> <newDisplayName>")
        exit(1)
    }
    let sectionID = CommandLine.arguments[2]
    let newDisplayName = CommandLine.arguments[3]
    updateSection(sectionIdentifier: sectionID, newDisplayName: newDisplayName)
    
case "delete":
    guard CommandLine.arguments.count == 3 else {
        print("Usage: sectionctl delete <sectionID>")
        exit(1)
    }
    let sectionID = CommandLine.arguments[2]
    deleteSection(sectionIdentifier: sectionID)
    
case "lists":
    listAvailableLists()
    
default:
    print("Unknown command: \(cmd)")
    exit(1)
}
