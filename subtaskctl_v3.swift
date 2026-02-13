#!/usr/bin/env swift

import Foundation
import Cocoa
import EventKit

// --------------------------------------------------
//  ReminderKit Private API Bridge v3
//  Try creating reminder via EventKit then setting parent
// --------------------------------------------------

final class ReminderKitBridge {
    private static var isLoaded = false
    
    @discardableResult
    static func loadFramework() -> Bool {
        if isLoaded { return true }
        
        let paths = [
            "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
            "/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal"
        ]
        
        for path in paths {
            if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                isLoaded = true
            }
        }
        
        return isLoaded
    }
    
    static var isAvailable: Bool {
        loadFramework()
        return NSClassFromString("REMStore") != nil
    }
}

class EventKitBridge {
    let eventStore = EKEventStore()
    
    func requestAccess() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        
        eventStore.requestFullAccessToReminders { success, _ in
            granted = success
            semaphore.signal()
        }
        
        semaphore.wait()
        return granted
    }
    
    func reminder(withID id: String) -> EKReminder? {
        return eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }
    
    func createReminder(title: String, inList calendar: EKCalendar) -> EKReminder? {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = calendar
        
        do {
            try eventStore.save(reminder, commit: true)
            return reminder
        } catch {
            print("❌  Failed to create reminder via EventKit: \(error)")
            return nil
        }
    }
}

// --------------------------------------------------
//  Approach 1: Create via EventKit, set parent via ReminderKit
// --------------------------------------------------

func createSubtaskApproach1(parentID: String, title: String) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit not available")
        return
    }
    
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard let parentReminder = ekBridge.reminder(withID: parentID) else {
        print("❌  Parent reminder not found: \(parentID)")
        return
    }
    
    print("📍 Approach 1: Create via EventKit, set parent via ReminderKit")
    print("   Parent: \(parentReminder.title ?? "untitled") in list: \(parentReminder.calendar.title)")
    
    // 1. Create a new reminder in the same list as parent
    guard let newReminder = ekBridge.createReminder(title: title, inList: parentReminder.calendar) else {
        return
    }
    let subtaskID = newReminder.calendarItemIdentifier
    print("   ✓ Created reminder via EventKit: \(subtaskID)")
    
    // 2. Now use ReminderKit to set parent relationship
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type,
          let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
        print("❌  ReminderKit classes not found")
        return
    }
    
    let store = storeClass.init()
    let initUserInteractiveSel = NSSelectorFromString("initUserInteractive:")
    if store.responds(to: initUserInteractiveSel) {
        _ = store.perform(initUserInteractiveSel, with: NSNumber(value: true))
    }
    
    // Fetch both reminders as REMReminder objects
    let fetchSel = NSSelectorFromString("fetchReminderWithDACalendarItemUniqueIdentifier:inList:error:")
    typealias FetchIMP = @convention(c) (AnyObject, Selector, NSString, AnyObject?, UnsafeMutablePointer<NSError?>) -> AnyObject?
    guard let fetchMethod = class_getInstanceMethod(type(of: store), fetchSel) else {
        print("❌  Fetch method not found")
        return
    }
    let fetchImp = unsafeBitCast(method_getImplementation(fetchMethod), to: FetchIMP.self)
    
    var fetchError: NSError? = nil
    guard let parentREMReminder = fetchImp(store, fetchSel, parentID as NSString, nil, &fetchError) as? NSObject else {
        print("❌  Failed to fetch parent REMReminder: \(fetchError?.localizedDescription ?? "unknown")")
        return
    }
    print("   ✓ Fetched parent REMReminder")
    
    fetchError = nil
    guard let subtaskREMReminder = fetchImp(store, fetchSel, subtaskID as NSString, nil, &fetchError) as? NSObject else {
        print("❌  Failed to fetch subtask REMReminder: \(fetchError?.localizedDescription ?? "unknown")")
        return
    }
    print("   ✓ Fetched subtask REMReminder")
    
    // 3. Create save request and update the subtask to set its parent
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // Get change item for the subtask
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard let subtaskChangeItem = saveRequest.perform(updateReminderSel, with: subtaskREMReminder)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get subtask change item")
        return
    }
    print("   ✓ Got subtask change item")
    
    // Check if REMReminderChangeItem has setParentReminder:
    print("\n   Checking available methods on change item...")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(type(of: subtaskChangeItem), &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.contains("parent") || name.contains("Parent") || name.contains("subtask") || name.contains("Subtask") {
                print("     \(name)")
            }
        }
        free(methods)
    }
    
    // Try using initWithObjectID:title:insertIntoParentReminderSubtaskContextChangeItem:
    // This suggests creating a new change item that inserts into a parent's subtask context
    
    // First, get the parent's change item and subtask context
    guard let parentChangeItem = saveRequest.perform(updateReminderSel, with: parentREMReminder)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get parent change item")
        return
    }
    
    let subtaskContextSel = NSSelectorFromString("subtaskContext")
    guard let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
        print("❌  Failed to get subtask context from parent")
        return
    }
    print("   ✓ Got parent's subtask context")
    
    // Try to move the existing reminder into the subtask context
    // Look for a method like addExistingReminder:toSubtaskContext: or similar
    print("\n   Checking REMSaveRequest methods for moving reminders...")
    methodCount = 0
    if let methods = class_copyMethodList(type(of: saveRequest), &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.contains("move") || name.contains("Move") || name.contains("copy") || name.contains("Copy") ||
               name.contains("existing") || name.contains("Existing") || name.contains("Reminder:to") {
                print("     \(name)")
            }
        }
        free(methods)
    }
    
    // Try _copyReminder:toReminderSubtaskContextChangeItem:
    let copyToSubtaskSel = NSSelectorFromString("_copyReminder:toReminderSubtaskContextChangeItem:")
    if saveRequest.responds(to: copyToSubtaskSel) {
        print("\n   Trying _copyReminder:toReminderSubtaskContextChangeItem:...")
        _ = saveRequest.perform(copyToSubtaskSel, with: subtaskREMReminder, with: subtaskContext)
        print("   ✓ Called copy method")
    }
    
    // Now save
    let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
    typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else {
        print("❌  Save method not found")
        return
    }
    let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
    
    var saveError: NSError?
    let success = saveImp(saveRequest, saveSel, &saveError)
    
    if success {
        print("\n✅  Save completed!")
        print("   Subtask ID: \(subtaskID)")
    } else {
        print("❌  Save failed: \(saveError?.localizedDescription ?? "unknown")")
    }
    
    // Verify
    Thread.sleep(forTimeInterval: 2.0)
    verifyReminder(id: subtaskID)
}

// --------------------------------------------------
//  Approach 2: Use the store's more comprehensive save method
// --------------------------------------------------

func createSubtaskApproach2(parentID: String, title: String) {
    guard ReminderKitBridge.loadFramework() else {
        print("❌  ReminderKit not available")
        return
    }
    
    guard let storeClass = NSClassFromString("REMStore") as? NSObject.Type,
          let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type else {
        print("❌  ReminderKit classes not found")
        return
    }
    
    let ekBridge = EventKitBridge()
    guard ekBridge.requestAccess() else {
        print("❌  Reminders access denied")
        return
    }
    
    guard ekBridge.reminder(withID: parentID) != nil else {
        print("❌  Parent reminder not found")
        return
    }
    
    print("📍 Approach 2: Use store's comprehensive save with syncToCloudKit:true")
    
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
    print("   ✓ Fetched parent")
    
    // Create save request
    let saveRequest = saveRequestClass.init()
    let initWithStoreSel = NSSelectorFromString("initWithStore:")
    if saveRequest.responds(to: initWithStoreSel) {
        _ = saveRequest.perform(initWithStoreSel, with: store)
    }
    
    // Get parent change item and subtask context
    let updateReminderSel = NSSelectorFromString("updateReminder:")
    guard let parentChangeItem = saveRequest.perform(updateReminderSel, with: parentREMReminder)?.takeUnretainedValue() as? NSObject else {
        return
    }
    
    let subtaskContextSel = NSSelectorFromString("subtaskContext")
    guard let subtaskContext = parentChangeItem.perform(subtaskContextSel)?.takeUnretainedValue() as? NSObject else {
        return
    }
    
    // Add subtask
    let addSubtaskSel = NSSelectorFromString("addReminderWithTitle:toReminderSubtaskContextChangeItem:")
    guard let subtaskChangeItem = saveRequest.perform(addSubtaskSel, with: title as NSString, with: subtaskContext)?.takeUnretainedValue() as? NSObject else {
        return
    }
    print("   ✓ Created subtask change item")
    
    // Try using the store's comprehensive save method with syncToCloudKit
    // saveSaveRequest:accountChangeItems:listChangeItems:... syncToCloudKit:performer:completion:
    let comprehensiveSaveSel = NSSelectorFromString("saveSaveRequest:accountChangeItems:listChangeItems:listSectionChangeItems:smartListChangeItems:smartListSectionChangeItems:templateChangeItems:templateSectionChangeItems:reminderChangeItems:author:replicaManagerProvider:error:")
    
    if store.responds(to: comprehensiveSaveSel) {
        print("   Found comprehensive save method - but it has complex signature")
    }
    
    // Let's check what saveRequestChangeEvents returns
    let changeEventsSel = NSSelectorFromString("saveRequestChangeEvents")
    if saveRequest.responds(to: changeEventsSel) {
        if let events = saveRequest.perform(changeEventsSel)?.takeUnretainedValue() {
            print("   Change events: \(events)")
        }
    }
    
    // Try the normal save but then force refresh
    let saveSel = NSSelectorFromString("saveSynchronouslyWithError:")
    typealias SaveIMP = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
    guard let saveMethod = class_getInstanceMethod(type(of: saveRequest), saveSel) else { return }
    let saveImp = unsafeBitCast(method_getImplementation(saveMethod), to: SaveIMP.self)
    
    var saveError: NSError?
    let success = saveImp(saveRequest, saveSel, &saveError)
    
    if success {
        print("   ✓ Local save succeeded")
        
        // Extract subtask ID
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
        print("   Subtask ID: \(subtaskID)")
        
        // Try to trigger remindd to refresh via distributed notification
        print("\n   Posting Reminders change notification...")
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.apple.reminders.datachanged"),
            object: nil,
            userInfo: nil
        )
        
        // Also try the accessibility notification
        DistributedNotificationCenter.default().post(
            name: NSNotification.Name("com.apple.accessibility.api.reminders.content.changed"),
            object: nil
        )
        
        // Give some time
        Thread.sleep(forTimeInterval: 3.0)
        verifyReminder(id: subtaskID)
    } else {
        print("❌  Save failed: \(saveError?.localizedDescription ?? "unknown")")
    }
}

// --------------------------------------------------
//  Verify reminder visibility
// --------------------------------------------------

func verifyReminder(id: String) {
    print("\n🔍 Verifying reminder \(id)...")
    
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "tell application \"Reminders\" to get every reminder whose id contains \"\(id)\""]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if output.contains(id) {
            print("   ✅ VISIBLE via AppleScript: \(output)")
        } else if output.isEmpty {
            print("   ❌ NOT visible via AppleScript (empty result)")
        } else {
            print("   ❌ NOT visible via AppleScript: \(output)")
        }
    } catch {
        print("   ❌ AppleScript error: \(error)")
    }
}

// --------------------------------------------------
//  CLI
// --------------------------------------------------

if CommandLine.arguments.count < 2 {
    print("Usage: subtaskctl_v3 <command> [options]")
    print("")
    print("Commands:")
    print("  approach1 <parentID> <title>  Create via EventKit then set parent")
    print("  approach2 <parentID> <title>  Use store save with notification")
    print("  verify <id>                   Verify if reminder is visible")
    exit(0)
}

let cmd = CommandLine.arguments[1]
switch cmd {
case "approach1":
    guard CommandLine.arguments.count == 4 else { print("Usage: ... approach1 <parentID> <title>"); exit(1) }
    createSubtaskApproach1(parentID: CommandLine.arguments[2], title: CommandLine.arguments[3])
    
case "approach2":
    guard CommandLine.arguments.count == 4 else { print("Usage: ... approach2 <parentID> <title>"); exit(1) }
    createSubtaskApproach2(parentID: CommandLine.arguments[2], title: CommandLine.arguments[3])
    
case "verify":
    guard CommandLine.arguments.count == 3 else { print("Usage: ... verify <id>"); exit(1) }
    verifyReminder(id: CommandLine.arguments[2])
    
default:
    print("Unknown command: \(cmd)")
    exit(1)
}
