#!/usr/bin/env swift

import Foundation
import Cocoa

// Investigate ReminderKit private API structure

let paths = [
    "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
    "/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal"
]

for path in paths {
    if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
        print("✅ Loaded: \(path)")
    }
}

// Investigate REMStore methods
if let storeClass = NSClassFromString("REMStore") as? NSObject.Type {
    print("\n=== REMStore Methods ===")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(storeClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            // Filter for interesting methods
            if name.contains("save") || name.contains("commit") || name.contains("sync") || 
               name.contains("refresh") || name.contains("Create") || name.contains("create") ||
               name.contains("add") || name.contains("subtask") || name.contains("Subtask") ||
               name.contains("child") || name.contains("Child") || name.contains("parent") ||
               name.contains("Parent") {
                print("  \(name)")
            }
        }
        free(methods)
    }
}

// Investigate REMSaveRequest methods
if let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type {
    print("\n=== REMSaveRequest Methods ===")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(saveRequestClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.contains("save") || name.contains("commit") || name.contains("sync") ||
               name.contains("add") || name.contains("subtask") || name.contains("Subtask") ||
               name.contains("create") || name.contains("Create") || name.contains("child") ||
               name.contains("Child") || name.contains("parent") || name.contains("Parent") {
                print("  \(name)")
            }
        }
        free(methods)
    }
}

// Investigate REMReminderChangeItem
if let changeItemClass = NSClassFromString("REMReminderChangeItem") {
    print("\n=== REMReminderChangeItem Methods ===")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(changeItemClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.contains("subtask") || name.contains("Subtask") || name.contains("child") ||
               name.contains("Child") || name.contains("parent") || name.contains("Parent") ||
               name.contains("set") {
                print("  \(name)")
            }
        }
        free(methods)
    }
}

// Check for REMReminder methods
if let reminderClass = NSClassFromString("REMReminder") {
    print("\n=== REMReminder Methods ===")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(reminderClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.contains("subtask") || name.contains("Subtask") || name.contains("child") ||
               name.contains("Child") || name.contains("parent") || name.contains("Parent") {
                print("  \(name)")
            }
        }
        free(methods)
    }
}

// Check what classes exist
print("\n=== Available ReminderKit Classes ===")
let classNames = [
    "REMStore", "REMSaveRequest", "REMReminder", "REMReminderChangeItem",
    "REMSubtask", "REMSubtaskContext", "REMSubtaskContextChangeItem",
    "REMCDReminder", "REMAccountStore", "REMChangeSet", "REMSyncEngine",
    "REMDataSource", "REMReminderStore", "REMLocalStore"
]
for name in classNames {
    if NSClassFromString(name) != nil {
        print("  ✅ \(name)")
    } else {
        print("  ❌ \(name)")
    }
}
