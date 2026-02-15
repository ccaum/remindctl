import EventKit
import Foundation
import SQLite3

/// Store for managing Reminders.app sections using ReminderKit private APIs.
/// Sections are visual groupings within lists, distinct from subtasks.
public final class SectionStore: @unchecked Sendable {
    
    public init() {}
    
    /// Fetch all sections for a given list using the SQLite database directly.
    /// This is more reliable than ReminderKit for read operations.
    public func fetchSections(forListID listID: String) -> [SectionItem] {
        let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
        )
        let fileManager = FileManager.default
        var results: [SectionItem] = []
        
        guard let enumerator = fileManager.enumerator(atPath: storesPath) else {
            return results
        }
        
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".sqlite") else { continue }
            let dbPath = (storesPath as NSString).appendingPathComponent(file)
            results.append(contentsOf: fetchSectionsFromDB(path: dbPath, listID: listID))
        }
        
        return results
    }
    
    /// Fetch section memberships (which reminders are in which sections) for a list.
    public func fetchSectionMemberships(forListID listID: String) -> [String: String] {
        let storesPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
        )
        let fileManager = FileManager.default
        var results: [String: String] = [:] // reminderID -> sectionID
        
        guard let enumerator = fileManager.enumerator(atPath: storesPath) else {
            return results
        }
        
        while let file = enumerator.nextObject() as? String {
            guard file.hasSuffix(".sqlite") else { continue }
            let dbPath = (storesPath as NSString).appendingPathComponent(file)
            let memberships = fetchMembershipsFromDB(path: dbPath, listID: listID)
            results.merge(memberships) { $1 }
        }
        
        return results
    }
    
    private func fetchSectionsFromDB(path: String, listID: String) -> [SectionItem] {
        var results: [SectionItem] = []
        var db: OpaquePointer?
        
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return results
        }
        defer { _ = sqlite3_close(db) }
        
        // First find the list's Z_PK and name
        let listQuery = "SELECT Z_PK, ZNAME FROM ZREMCDBASELIST WHERE ZCKIDENTIFIER = ? AND ZMARKEDFORDELETION = 0;"
        var listStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, listQuery, -1, &listStmt, nil) == SQLITE_OK else {
            return results
        }
        defer { _ = sqlite3_finalize(listStmt) }
        
        // Use SQLITE_TRANSIENT to ensure the string is copied
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        listID.withCString { cString in
            _ = sqlite3_bind_text(listStmt, 1, cString, -1, SQLITE_TRANSIENT)
        }
        
        var listPK: Int32 = -1
        var listName: String = ""
        if sqlite3_step(listStmt) == SQLITE_ROW {
            listPK = sqlite3_column_int(listStmt, 0)
            if let namePtr = sqlite3_column_text(listStmt, 1) {
                listName = String(cString: namePtr)
            }
        }
        
        guard listPK >= 0 else { return results }
        
        // Now fetch sections for this list
        let sectionQuery = """
            SELECT ZCKIDENTIFIER, ZDISPLAYNAME 
            FROM ZREMCDBASESECTION 
            WHERE ZLIST = ? AND ZMARKEDFORDELETION = 0;
        """
        var sectionStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sectionQuery, -1, &sectionStmt, nil) == SQLITE_OK else {
            return results
        }
        defer { _ = sqlite3_finalize(sectionStmt) }
        
        _ = sqlite3_bind_int(sectionStmt, 1, listPK)
        
        while sqlite3_step(sectionStmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(sectionStmt, 0),
                  let namePtr = sqlite3_column_text(sectionStmt, 1) else {
                continue
            }
            
            let sectionID = String(cString: idPtr)
            let displayName = String(cString: namePtr)
            
            results.append(SectionItem(
                id: sectionID,
                displayName: displayName,
                listID: listID,
                listName: listName
            ))
        }
        
        return results
    }
    
    private func fetchMembershipsFromDB(path: String, listID: String) -> [String: String] {
        var results: [String: String] = [:]
        var db: OpaquePointer?
        
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return results
        }
        defer { _ = sqlite3_close(db) }
        
        let query = "SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA FROM ZREMCDBASELIST WHERE ZCKIDENTIFIER = ? AND ZMARKEDFORDELETION = 0;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return results
        }
        defer { _ = sqlite3_finalize(stmt) }
        
        // Use SQLITE_TRANSIENT to ensure the string is copied
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        listID.withCString { cString in
            _ = sqlite3_bind_text(stmt, 1, cString, -1, SQLITE_TRANSIENT)
        }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(stmt, 0) {
                let size = sqlite3_column_bytes(stmt, 0)
                let data = Data(bytes: blob, count: Int(size))
                
                if let json = try? JSONDecoder().decode(SectionMembershipsData.self, from: data) {
                    for membership in json.memberships {
                        results[membership.memberID] = membership.groupID
                    }
                }
            }
        }
        
        return results
    }
}

// MARK: - ReminderKit Section Operations

extension RemindersStore {
    
    /// Create a new section in the specified list using ReminderKit private APIs.
    ///
    /// - Parameters:
    ///   - displayName: The name of the section
    ///   - listName: The name of the list to add the section to
    /// - Returns: The created section
    public func createSection(displayName: String, listName: String) async throws -> SectionItem {
        guard ReminderKitBridge.loadFramework() else {
            throw RemindCoreError.operationFailed("ReminderKit framework not available")
        }
        
        guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMStore class not found")
        }
        
        guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMSaveRequest class not found")
        }
        
        // Get the list's calendar identifier
        let calendar = try self.calendarByName(listName)
        let listID = calendar.calendarIdentifier
        
        guard let objectIDClass = NSClassFromString("REMObjectID") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMObjectID class not found")
        }
        
        // 1. Create REMStore
        let store = storeClass.init()
        let initSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initSel) {
            _ = store.perform(initSel, with: NSNumber(value: true))
        }
        
        // 2. Create list ObjectID from UUID string and entity name
        guard let listUUID = NSUUID(uuidString: listID) else {
            throw RemindCoreError.operationFailed("Invalid list ID format: \(listID)")
        }
        
        let objectIDFromUUIDSel = NSSelectorFromString("objectIDWithUUID:entityName:")
        guard (objectIDClass as AnyObject).responds(to: objectIDFromUUIDSel) else {
            throw RemindCoreError.operationFailed("REMObjectID does not respond to objectIDWithUUID:entityName:")
        }
        
        guard let listObjectID = (objectIDClass as AnyObject).perform(objectIDFromUUIDSel, with: listUUID, with: "REMCDList" as NSString)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create list object ID")
        }
        
        // 3. Fetch the REMList using objectID
        let fetchListSel = NSSelectorFromString("fetchListWithObjectID:error:")
        guard store.responds(to: fetchListSel) else {
            throw RemindCoreError.operationFailed("REMStore does not support fetchListWithObjectID:error:")
        }
        
        typealias FetchListIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchListSel) else {
            throw RemindCoreError.operationFailed("Failed to get fetch list method")
        }
        let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchListIMP.self)
        
        var fetchError: NSError? = nil
        guard let remList = fetchImp(store, fetchListSel, listObjectID, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "List not found"
            throw RemindCoreError.operationFailed("Failed to fetch list: \(errorMsg)")
        }
        
        // 3. Create REMSaveRequest
        let saveRequest = saveRequestClass.init()
        let initWithStoreSel = NSSelectorFromString("initWithStore:")
        if saveRequest.responds(to: initWithStoreSel) {
            _ = saveRequest.perform(initWithStoreSel, with: store)
        }
        
        // 4. Get the list change item
        let updateListSel = NSSelectorFromString("updateList:")
        guard saveRequest.responds(to: updateListSel),
              let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get list change item")
        }
        
        // 5. Get the sections context change item
        let sectionsContextSel = NSSelectorFromString("sectionsContextChangeItem")
        guard listChangeItem.responds(to: sectionsContextSel),
              let sectionsContext = listChangeItem.perform(sectionsContextSel)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get sections context")
        }
        
        // 6. Add section with display name
        let addSectionSel = NSSelectorFromString("addListSectionWithDisplayName:toListSectionContextChangeItem:")
        guard saveRequest.responds(to: addSectionSel) else {
            throw RemindCoreError.operationFailed("REMSaveRequest does not support addListSectionWithDisplayName:toListSectionContextChangeItem:")
        }
        
        guard let sectionChangeItem = saveRequest.perform(addSectionSel, with: displayName as NSString, with: sectionsContext)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create section")
        }
        
        // 7. Save
        let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
        guard saveRequest.responds(to: saveSel) else {
            throw RemindCoreError.operationFailed("REMSaveRequest does not respond to saveSynchronouslyWithError:")
        }
        
        typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
            throw RemindCoreError.operationFailed("Failed to get save method")
        }
        let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
        
        var saveError: NSError?
        let success = saveImp(saveRequest, saveSel, &saveError)
        
        if !success {
            throw RemindCoreError.operationFailed("Failed to save section: \(saveError?.localizedDescription ?? "unknown error")")
        }
        
        // 8. Extract the section ID
        // Try to get the objectID from the change item's storage
        var sectionID = UUID().uuidString
        
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
        
        return SectionItem(
            id: sectionID,
            displayName: displayName,
            listID: listID,
            listName: listName
        )
    }
    
    /// Delete a section from a list using ReminderKit private APIs.
    ///
    /// - Parameters:
    ///   - sectionID: The ID of the section to delete
    ///   - listName: The name of the list containing the section
    public func deleteSection(sectionID: String, listName: String) async throws {
        guard ReminderKitBridge.loadFramework() else {
            throw RemindCoreError.operationFailed("ReminderKit framework not available")
        }
        
        guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMStore class not found")
        }
        
        guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMSaveRequest class not found")
        }
        
        guard let objectIDClass = NSClassFromString("REMObjectID") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMObjectID class not found")
        }
        
        // 1. Create REMStore
        let store = storeClass.init()
        let initSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initSel) {
            _ = store.perform(initSel, with: NSNumber(value: true))
        }
        
        // 2. Create section object ID from UUID and entity name
        let objectIDFromUUIDSel = NSSelectorFromString("objectIDWithUUID:entityName:")
        guard (objectIDClass as AnyObject).responds(to: objectIDFromUUIDSel) else {
            throw RemindCoreError.operationFailed("REMObjectID does not respond to objectIDWithUUID:entityName:")
        }
        
        guard let sectionUUID = NSUUID(uuidString: sectionID) else {
            throw RemindCoreError.operationFailed("Invalid section ID format")
        }
        
        guard let sectionObjectID = (objectIDClass as AnyObject).perform(objectIDFromUUIDSel, with: sectionUUID, with: "REMCDListSection" as NSString)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create section object ID")
        }
        
        // 3. Fetch the section
        let fetchSectionSel = NSSelectorFromString("fetchListSectionWithObjectID:error:")
        guard store.responds(to: fetchSectionSel) else {
            throw RemindCoreError.operationFailed("REMStore does not support fetchListSectionWithObjectID:error:")
        }
        
        typealias FetchIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSectionSel) else {
            throw RemindCoreError.operationFailed("Failed to get fetch section method")
        }
        let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
        
        var fetchError: NSError? = nil
        guard let remSection = fetchImp(store, fetchSectionSel, sectionObjectID, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "Section not found"
            throw RemindCoreError.operationFailed("Failed to fetch section: \(errorMsg)")
        }
        
        // 4. Create REMSaveRequest
        let saveRequest = saveRequestClass.init()
        let initWithStoreSel = NSSelectorFromString("initWithStore:")
        if saveRequest.responds(to: initWithStoreSel) {
            _ = saveRequest.perform(initWithStoreSel, with: store)
        }
        
        // 5. Get section change item via updateListSection:
        let updateSectionSel = NSSelectorFromString("updateListSection:")
        guard saveRequest.responds(to: updateSectionSel),
              let sectionChangeItem = saveRequest.perform(updateSectionSel, with: remSection)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get section change item")
        }
        
        // 6. Call removeFromList on the section change item
        let removeFromListSel = NSSelectorFromString("removeFromList")
        guard sectionChangeItem.responds(to: removeFromListSel) else {
            throw RemindCoreError.operationFailed("Section change item does not respond to removeFromList")
        }
        _ = sectionChangeItem.perform(removeFromListSel)
        
        // 7. Save
        let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
        typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
            throw RemindCoreError.operationFailed("Failed to get save method")
        }
        let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
        
        var saveError: NSError?
        let success = saveImp(saveRequest, saveSel, &saveError)
        
        if !success {
            throw RemindCoreError.operationFailed("Failed to delete section: \(saveError?.localizedDescription ?? "unknown error")")
        }
    }
    
    /// Move a reminder to a section within the same list.
    /// Uses REMMemberships wrapper class for proper section assignment (matches working reminderctl.swift pattern).
    ///
    /// - Parameters:
    ///   - reminderID: The ID of the reminder to move
    ///   - sectionID: The ID of the section to move to, or nil to remove from section
    public func moveReminderToSection(reminderID: String, sectionID: String?) async throws {
        guard ReminderKitBridge.loadFramework() else {
            throw RemindCoreError.operationFailed("ReminderKit framework not available")
        }
        
        guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMStore class not found")
        }
        
        guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMSaveRequest class not found")
        }
        
        guard let listClass = NSClassFromString("REMList") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMList class not found")
        }
        
        guard let membershipClass = NSClassFromString("REMMembership") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMMembership class not found")
        }
        
        guard let membershipsClass = NSClassFromString("REMMemberships") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMMemberships class not found")
        }
        
        // Get the reminder to find its list
        let ekReminder = try reminder(withID: reminderID)
        let listID = ekReminder.calendar.calendarIdentifier
        
        guard let listUUID = NSUUID(uuidString: listID) else {
            throw RemindCoreError.operationFailed("Invalid list ID format: \(listID)")
        }
        
        // 1. Create REMStore
        let store = storeClass.init()
        let initSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initSel) {
            _ = store.perform(initSel, with: NSNumber(value: true))
        }
        
        // 2. Create list ObjectID using REMList.objectIDWithUUID: (simpler, single-argument version)
        let objectIDWithUUIDSel = NSSelectorFromString("objectIDWithUUID:")
        guard (listClass as AnyObject).responds(to: objectIDWithUUIDSel) else {
            throw RemindCoreError.operationFailed("REMList does not respond to objectIDWithUUID:")
        }
        
        guard let listObjectID = (listClass as AnyObject).perform(objectIDWithUUIDSel, with: listUUID)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create list object ID")
        }
        
        // 3. Fetch the REMList using objectID
        let fetchListSel = NSSelectorFromString("fetchListWithObjectID:error:")
        typealias FetchListIMP = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchListSel) else {
            throw RemindCoreError.operationFailed("Failed to get fetch list method")
        }
        let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchListIMP.self)
        
        var fetchError: NSError? = nil
        guard let remList = fetchImp(store, fetchListSel, listObjectID, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "List not found"
            throw RemindCoreError.operationFailed("Failed to fetch list: \(errorMsg)")
        }
        
        // 4. Create REMSaveRequest
        let saveRequest = saveRequestClass.init()
        let initWithStoreSel = NSSelectorFromString("initWithStore:")
        if saveRequest.responds(to: initWithStoreSel) {
            _ = saveRequest.perform(initWithStoreSel, with: store)
        }
        
        // 5. Get the list change item
        let updateListSel = NSSelectorFromString("updateList:")
        guard saveRequest.responds(to: updateListSel),
              let listChangeItem = saveRequest.perform(updateListSel, with: remList)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get list change item")
        }
        
        // 6. Get the sections context change item
        let sectionsContextSel = NSSelectorFromString("sectionsContextChangeItem")
        guard listChangeItem.responds(to: sectionsContextSel),
              let sectionsContext = listChangeItem.perform(sectionsContextSel)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get sections context")
        }
        
        // 7. Get current memberships from database and create membership objects
        let sectionStore = SectionStore()
        let existingMemberships = sectionStore.fetchSectionMemberships(forListID: listID)
        
        var membershipObjects: [NSObject] = []
        let initMembershipSel = NSSelectorFromString("initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:")
        
        typealias MembershipInitIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Bool, AnyObject) -> AnyObject?
        
        // Add existing memberships (excluding the one we're updating)
        for (memID, grpID) in existingMemberships where memID != reminderID {
            guard let memUUID = NSUUID(uuidString: memID),
                  let grpUUID = NSUUID(uuidString: grpID) else { continue }
            
            let membershipInstance = membershipClass.init()
            if let method = class_getInstanceMethod(membershipClass, initMembershipSel) {
                let imp = unsafeBitCast(method_getImplementation(method), to: MembershipInitIMP.self)
                if let result = imp(membershipInstance, initMembershipSel, memUUID, grpUUID, false, NSDate()) as? NSObject {
                    membershipObjects.append(result)
                }
            }
        }
        
        // Add the new membership if sectionID is provided
        if let sectionID = sectionID {
            guard let memUUID = NSUUID(uuidString: reminderID),
                  let grpUUID = NSUUID(uuidString: sectionID) else {
                throw RemindCoreError.operationFailed("Invalid reminder or section ID format")
            }
            
            let membershipInstance = membershipClass.init()
            if let method = class_getInstanceMethod(membershipClass, initMembershipSel) {
                let imp = unsafeBitCast(method_getImplementation(method), to: MembershipInitIMP.self)
                if let result = imp(membershipInstance, initMembershipSel, memUUID, grpUUID, false, NSDate()) as? NSObject {
                    membershipObjects.append(result)
                }
            }
        }
        
        // 8. Create REMMemberships wrapper object (KEY: use this wrapper class, not plain NSSet)
        let membershipsSet = NSSet(array: membershipObjects)
        let initWithMembershipsSel = NSSelectorFromString("initWithMemberships:")
        
        let membershipsInstance = membershipsClass.init()
        guard membershipsInstance.responds(to: initWithMembershipsSel),
              let memberships = membershipsInstance.perform(initWithMembershipsSel, with: membershipsSet)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create REMMemberships object")
        }
        
        // 9. Set the unsaved memberships using the wrapper object
        let setMembershipsSel = NSSelectorFromString("setUnsavedMembershipsOfRemindersInSections:")
        guard sectionsContext.responds(to: setMembershipsSel) else {
            throw RemindCoreError.operationFailed("Sections context does not respond to setUnsavedMembershipsOfRemindersInSections:")
        }
        _ = sectionsContext.perform(setMembershipsSel, with: memberships)
        
        // 10. Save
        let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
        typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
            throw RemindCoreError.operationFailed("Failed to get save method")
        }
        let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
        
        var saveError: NSError?
        let success = saveImp(saveRequest, saveSel, &saveError)
        
        if !success {
            throw RemindCoreError.operationFailed("Failed to move reminder to section: \(saveError?.localizedDescription ?? "unknown error")")
        }
    }
    
    // Helper to get calendar by name (used internally)
    func calendarByName(_ name: String) throws -> EKCalendar {
        let calendars = eventStore.calendars(for: .reminder).filter { $0.title == name }
        guard let calendar = calendars.first else {
            throw RemindCoreError.listNotFound(name)
        }
        return calendar
    }
}

// SQLite is imported via `import SQLite3`
