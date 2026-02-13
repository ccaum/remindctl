import EventKit
import Foundation

// MARK: - Native Tag Support via ReminderKit Private APIs

extension RemindersStore {
    
    /// Add a native tag to a reminder using ReminderKit's private API.
    ///
    /// This creates a tag that appears in Reminders.app's tag browser,
    /// not just a hashtag in the notes field.
    ///
    /// The API flow:
    /// 1. Create REMStore with user interactive mode
    /// 2. Fetch the REMReminder using fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:
    /// 3. Create REMSaveRequest with store
    /// 4. Call updateReminder: to get the reminder's change item
    /// 5. Get hashtagContext from the change item
    /// 6. Use addHashtagWithType:name: to add the tag
    /// 7. Commit the save request with saveSynchronouslyWithError:
    ///
    /// - Parameters:
    ///   - tag: The tag name to add (without #)
    ///   - reminderID: The EKReminder.calendarItemIdentifier
    public func addTag(_ tag: String, to reminderID: String) async throws {
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
        
        // 1. Create REMStore with user interactive mode
        let store = storeClass.init()
        let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initUserInteractiveSel) {
            _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
        }
        
        // 2. Fetch the REMReminder
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
        guard let remReminder = fetchImp(store, fetchSel, reminderID as NSString, nil, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
            throw RemindCoreError.operationFailed("Failed to fetch reminder: \(errorMsg)")
        }
        
        // 3. Create REMSaveRequest with store
        let saveRequest = saveRequestClass.init()
        let initWithStoreSel = NSSelectorFromString("initWithStore:")
        if saveRequest.responds(to: initWithStoreSel) {
            _ = saveRequest.perform(initWithStoreSel, with: store)
        }
        
        // 4. Call updateReminder: to get the reminder's change item
        let updateReminderSel = NSSelectorFromString("updateReminder:")
        guard saveRequest.responds(to: updateReminderSel),
              let changeItem = saveRequest.perform(updateReminderSel, with: remReminder)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get reminder change item")
        }
        
        // 5. Get hashtagContext from the change item
        let hashtagContextSel = NSSelectorFromString("hashtagContext")
        guard changeItem.responds(to: hashtagContextSel),
              let hashtagContext = changeItem.perform(hashtagContextSel)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get hashtag context from reminder")
        }
        
        // 6. Use addHashtagWithType:name: to add the tag
        // Type 0 appears to be user-created tags (most common)
        let addHashtagSel = NSSelectorFromString("addHashtagWithType:name:")
        guard hashtagContext.responds(to: addHashtagSel) else {
            throw RemindCoreError.operationFailed("REMReminderHashtagContextChangeItem does not respond to addHashtagWithType:name:")
        }
        
        // Use NSInvocation-like approach for the Int64 parameter
        typealias AddHashtagIMP = @convention(c) (AnyObject, Selector, Int64, NSString) -> AnyObject?
        guard let addHashtagMethod = class_getInstanceMethod(type(of: hashtagContext), addHashtagSel) else {
            throw RemindCoreError.operationFailed("Failed to get addHashtagWithType:name: method implementation")
        }
        let addHashtagImp = unsafeBitCast(method_getImplementation(addHashtagMethod), to: AddHashtagIMP.self)
        
        // Type 0 = user-created tag
        _ = addHashtagImp(hashtagContext, addHashtagSel, 0, tag as NSString)
        
        // 7. Commit the save request
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
            throw RemindCoreError.operationFailed("Failed to add tag: \(saveError?.localizedDescription ?? "unknown error")")
        }
    }
    
    /// Remove a native tag from a reminder using ReminderKit's private API.
    ///
    /// - Parameters:
    ///   - tag: The tag name to remove (without #)
    ///   - reminderID: The EKReminder.calendarItemIdentifier
    public func removeTag(_ tag: String, from reminderID: String) async throws {
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
        
        // 1. Create REMStore with user interactive mode
        let store = storeClass.init()
        let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
        if store.responds(to: initUserInteractiveSel) {
            _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
        }
        
        // 2. Fetch the REMReminder
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
        guard let remReminder = fetchImp(store, fetchSel, reminderID as NSString, nil, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
            throw RemindCoreError.operationFailed("Failed to fetch reminder: \(errorMsg)")
        }
        
        // Get current hashtags to find the one to remove (returns NSSet)
        let hashtagsSel = NSSelectorFromString("hashtags")
        guard remReminder.responds(to: hashtagsSel),
              let hashtagsObj = remReminder.perform(hashtagsSel)?.takeUnretainedValue() else {
            throw RemindCoreError.operationFailed("Failed to get hashtags from reminder")
        }
        
        // hashtags property returns an NSSet
        let hashtagsSet: NSSet
        if let set = hashtagsObj as? NSSet {
            hashtagsSet = set
        } else if let array = hashtagsObj as? NSArray {
            hashtagsSet = NSSet(array: array as! [Any])
        } else {
            throw RemindCoreError.operationFailed("Unexpected hashtags type")
        }
        
        // Find the hashtag with the matching name
        var targetHashtag: NSObject? = nil
        let nameSel = NSSelectorFromString("name")
        for hashtagObj in hashtagsSet {
            guard let hashtag = hashtagObj as? NSObject,
                  hashtag.responds(to: nameSel),
                  let hashtagName = hashtag.perform(nameSel)?.takeUnretainedValue() as? String else {
                continue
            }
            if hashtagName == tag {
                targetHashtag = hashtag
                break
            }
        }
        
        guard let hashtagToRemove = targetHashtag else {
            // Tag not found - nothing to do
            return
        }
        
        // 3. Create REMSaveRequest with store
        let saveRequest = saveRequestClass.init()
        let initWithStoreSel = NSSelectorFromString("initWithStore:")
        if saveRequest.responds(to: initWithStoreSel) {
            _ = saveRequest.perform(initWithStoreSel, with: store)
        }
        
        // 4. Call updateReminder: to get the reminder's change item
        let updateReminderSel = NSSelectorFromString("updateReminder:")
        guard saveRequest.responds(to: updateReminderSel),
              let changeItem = saveRequest.perform(updateReminderSel, with: remReminder)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get reminder change item")
        }
        
        // 5. Get hashtagContext from the change item
        let hashtagContextSel = NSSelectorFromString("hashtagContext")
        guard changeItem.responds(to: hashtagContextSel),
              let hashtagContext = changeItem.perform(hashtagContextSel)?.takeUnretainedValue() as? NSObject else {
            throw RemindCoreError.operationFailed("Failed to get hashtag context from reminder")
        }
        
        // 6. Use removeHashtag: to remove the tag
        let removeHashtagSel = NSSelectorFromString("removeHashtag:")
        guard hashtagContext.responds(to: removeHashtagSel) else {
            throw RemindCoreError.operationFailed("REMReminderHashtagContextChangeItem does not respond to removeHashtag:")
        }
        _ = hashtagContext.perform(removeHashtagSel, with: hashtagToRemove)
        
        // 7. Commit the save request
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
            throw RemindCoreError.operationFailed("Failed to remove tag: \(saveError?.localizedDescription ?? "unknown error")")
        }
    }
    
    /// Get native tags for a reminder using ReminderKit's private API.
    ///
    /// - Parameter reminderID: The EKReminder.calendarItemIdentifier
    /// - Returns: Array of tag names
    public func tags(for reminderID: String) async throws -> [String] {
        // Ensure ReminderKit is loaded
        guard ReminderKitBridge.loadFramework() else {
            throw RemindCoreError.operationFailed("ReminderKit framework not available")
        }
        
        // Get required classes
        guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type else {
            throw RemindCoreError.operationFailed("REMStore class not found")
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
            throw RemindCoreError.operationFailed("REMStore does not support fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
        }
        
        typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
            throw RemindCoreError.operationFailed("Failed to get fetch method implementation")
        }
        let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
        
        var fetchError: NSError? = nil
        guard let remReminder = fetchImp(store, fetchSel, reminderID as NSString, nil, &fetchError) as? NSObject else {
            let errorMsg = fetchError?.localizedDescription ?? "Reminder not found"
            throw RemindCoreError.operationFailed("Failed to fetch reminder: \(errorMsg)")
        }
        
        // Get hashtags from the reminder (returns NSSet)
        let hashtagsSel = NSSelectorFromString("hashtags")
        guard remReminder.responds(to: hashtagsSel) else {
            return []
        }
        
        guard let hashtagsObj = remReminder.perform(hashtagsSel)?.takeUnretainedValue() else {
            return []
        }
        
        // hashtags property returns an NSSet, not NSArray
        let hashtagsSet: NSSet
        if let set = hashtagsObj as? NSSet {
            hashtagsSet = set
        } else if let array = hashtagsObj as? NSArray {
            hashtagsSet = NSSet(array: array as! [Any])
        } else {
            return []
        }
        
        // Extract tag names
        var tagNames: [String] = []
        let nameSel = NSSelectorFromString("name")
        for hashtagObj in hashtagsSet {
            guard let hashtag = hashtagObj as? NSObject,
                  hashtag.responds(to: nameSel),
                  let name = hashtag.perform(nameSel)?.takeUnretainedValue() as? String else {
                continue
            }
            tagNames.append(name)
        }
        
        return tagNames.sorted()
    }
}
