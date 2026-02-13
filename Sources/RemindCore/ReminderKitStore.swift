import Foundation
import EventKit

// MARK: - Sendable Wrapper for NSObject

/// A wrapper that allows passing NSObject across isolation boundaries.
/// Used for ReminderKit private API bridging where we control the usage.
private struct UnsafeNSObjectBox: @unchecked Sendable {
    let object: NSObject
}

// MARK: - ReminderKit Bridge

/// Bridges to private ReminderKit.framework APIs for subtask creation.
/// Uses dlopen + NSClassFromString to avoid linking against private frameworks.
public final class ReminderKitBridge: @unchecked Sendable {
    nonisolated(unsafe) private static var frameworkHandle: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var isLoaded = false
    private static let loadLock = NSLock()
    
    /// Load ReminderKit.framework dynamically
    @discardableResult
    public static func loadFramework() -> Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        
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
    public static var isAvailable: Bool {
        loadFramework()
        return NSClassFromString("REMSaveRequest") != nil && NSClassFromString("REMStore") != nil
    }
}

// MARK: - Subtask Creation Extension

extension RemindersStore {
    
    /// Create a subtask under the specified parent reminder using ReminderKit's private API.
    ///
    /// This method uses the following ReminderKit classes:
    /// - `REMStore`: The ReminderKit data store
    /// - `REMSaveRequest`: The save request container
    /// - `REMReminderChangeItem`: Change item for modifications
    ///
    /// The API flow:
    /// 1. Create REMStore with user interactive mode
    /// 2. Fetch the parent REMReminder using fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:
    /// 3. Create REMSaveRequest with store
    /// 4. Call updateReminder: to get the parent's change item
    /// 5. Get subtaskContext from the parent change item
    /// 6. Use addReminderWithTitle:toReminderSubtaskContextChangeItem: to create the subtask
    /// 7. Set additional properties (notes, due date, priority)
    /// 8. Commit the save request with saveSynchronouslyWithError:
    ///
    /// - Parameters:
    ///   - draft: The reminder draft with title, notes, etc.
    ///   - listName: The list containing the parent reminder
    ///   - parentID: The EKReminder.calendarItemIdentifier of the parent reminder
    /// - Returns: The created subtask as a ReminderItem
    public func createSubtask(_ draft: ReminderDraft, listName: String, parentID: String) async throws -> ReminderItem {
        // Ensure ReminderKit is loaded
        guard ReminderKitBridge.loadFramework() else {
            throw RemindCoreError.operationFailed("ReminderKit framework not available")
        }
        
        // Get required classes
        guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMStore class not found")
        }
        
        guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMSaveRequest class not found")
        }
        
        // Get the parent EKReminder and its calendar for metadata
        let parentEKReminder = try reminder(withID: parentID)
        let calendar = parentEKReminder.calendar!
        
        // 1. Create REMStore with user interactive mode
        let store = storeClass.init()
        let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initUserInteractiveSel) {
            _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
        }
        
        // 2. Fetch the parent REMReminder using the direct method
        let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
        guard store.responds(to: fetchSel) else {
            throw RemindCoreError.operationFailed("REMStore does not support fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
        }
        
        typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
            throw RemindCoreError.operationFailed("Failed to get fetch method implementation")
        }
        let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
        
        var fetchError: NSError? = nil
        guard let parentREMReminder = fetchImp(store, fetchSel, parentID as NSString, nil, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
            throw RemindCoreError.operationFailed("Failed to fetch parent reminder: \(errorMsg)")
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
            throw RemindCoreError.operationFailed("Failed to get parent reminder change item")
        }
        
        // 5. Get subtaskContext from the parent change item
        let subtaskContextSel = NSSelectorFromString("subtaskContext")
        guard parentChangeItem.responds(to: subtaskContextSel),
              let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get subtask context from parent")
        }
        
        // 6. Use addReminderWithTitle:toReminderSubtaskContextChangeItem: to create the subtask
        let addSubtaskSel = NSSelectorFromString("addReminderWithTitle:toReminderSubtaskContextChangeItem:")
        guard saveRequest.responds(to: addSubtaskSel) else {
            throw RemindCoreError.operationFailed("REMSaveRequest does not respond to addReminderWithTitle:toReminderSubtaskContextChangeItem:")
        }
        
        guard let subtaskChangeItem = saveRequest.perform(addSubtaskSel, with: draft.title as NSString, with: subtaskContext)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to create subtask change item")
        }
        
        // 7. Set additional properties on the subtask
        if let notes = draft.notes {
            let setNotesSel = NSSelectorFromString("setNotes:")
            if subtaskChangeItem.responds(to: setNotesSel) {
                _ = subtaskChangeItem.perform(setNotesSel, with: notes as NSString)
            }
        }
        
        if let dueDate = draft.dueDate {
            let setDueDateSel = NSSelectorFromString("setDueDateComponents:")
            if subtaskChangeItem.responds(to: setDueDateSel) {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate) as NSDateComponents
                _ = subtaskChangeItem.perform(setDueDateSel, with: components)
            }
        }
        
        if draft.priority != .none {
            let setPrioritySel = NSSelectorFromString("setPriority:")
            if subtaskChangeItem.responds(to: setPrioritySel) {
                _ = subtaskChangeItem.perform(setPrioritySel, with: NSNumber(value: draft.priority.eventKitValue))
            }
        }
        
        // 8. Commit the save request
        let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
        guard saveRequest.responds(to: saveSel) else {
            throw RemindCoreError.operationFailed("REMSaveRequest does not respond to saveSynchronouslyWithError:")
        }
        
        typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
        guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
            throw RemindCoreError.operationFailed("Failed to get save method implementation")
        }
        let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
        
        var saveError: NSError?
        let success = saveImp(saveRequest, saveSel, &saveError)
        
        if !success {
            throw RemindCoreError.operationFailed("Failed to save subtask: \(saveError?.localizedDescription ?? "unknown error")")
        }
        
        // 9. Extract the created reminder's ID for the return value
        var subtaskID = UUID().uuidString
        
        let reminderSel = NSSelectorFromString("reminder")
        if subtaskChangeItem.responds(to: reminderSel),
           let remReminder = subtaskChangeItem.perform(reminderSel)?.takeUnretainedValue() as? NSObject {
            // Get the object ID to extract the UUID
            let objectIDSel = NSSelectorFromString("remObjectID")
            if remReminder.responds(to: objectIDSel),
               let objectID = remReminder.perform(objectIDSel)?.takeUnretainedValue() as? NSObject {
                // Get string representation (format: <x-apple-reminderkit://REMCDReminder/UUID>)
                let strRepSel = NSSelectorFromString("stringRepresentation")
                if objectID.responds(to: strRepSel),
                   let strRep = objectID.perform(strRepSel)?.takeUnretainedValue() as? String {
                    // Extract UUID from the URL format
                    if let range = strRep.range(of: "REMCDReminder/") {
                        let uuidPart = String(strRep[range.upperBound...])
                        // Remove trailing > if present
                        subtaskID = uuidPart.trimmingCharacters(in: CharacterSet(charactersIn: ">"))
                    }
                }
            }
        }
        
        return ReminderItem(
            id: subtaskID,
            title: draft.title,
            notes: draft.notes,
            isCompleted: false,
            completionDate: nil,
            priority: draft.priority,
            dueDate: draft.dueDate,
            listID: calendar.calendarIdentifier,
            listName: calendar.title,
            parentID: parentID
        )
    }
}
