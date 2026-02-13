#!/usr/bin/env swift

import Foundation
import Cocoa

// --------------------------------------------------
//  Investigate ReminderKit Section APIs
// --------------------------------------------------

// Load ReminderKit
let paths = [
    "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
    "/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal"
]

var loaded = false
for path in paths {
    if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
        print("✓ Loaded: \(path)")
        loaded = true
    }
}

if !loaded {
    print("❌ Failed to load ReminderKit")
    exit(1)
}

// Investigate classes related to sections
let classNames = [
    "REMListSection",
    "REMListSectionChangeItem",
    "REMSaveRequest",
    "REMStore",
    "REMList",
    "REMListChangeItem",
    "REMReminderSubtaskContextChangeItem"
]

func printMethods(forClassName className: String, filter: String? = nil) {
    guard let cls = NSClassFromString(className) else {
        print("❌ Class not found: \(className)")
        return
    }
    
    print("\n========================================")
    print("Class: \(className)")
    print("========================================")
    
    // Instance methods
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(cls, &methodCount) {
        print("\nInstance Methods (\(methodCount)):")
        var methodNames: [String] = []
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if let filter = filter {
                if name.lowercased().contains(filter.lowercased()) {
                    methodNames.append(name)
                }
            } else {
                methodNames.append(name)
            }
        }
        methodNames.sort()
        for name in methodNames {
            print("  - \(name)")
        }
        free(methods)
    }
    
    // Class methods
    if let metaClass = object_getClass(cls) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
            print("\nClass Methods (\(classMethodCount)):")
            var methodNames: [String] = []
            for i in 0..<Int(classMethodCount) {
                let method = classMethods[i]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                if let filter = filter {
                    if name.lowercased().contains(filter.lowercased()) {
                        methodNames.append(name)
                    }
                } else {
                    methodNames.append(name)
                }
            }
            methodNames.sort()
            for name in methodNames {
                print("  + \(name)")
            }
            free(classMethods)
        }
    }
}

// Print methods for each class
for className in classNames {
    printMethods(forClassName: className, filter: nil)
}

// Look specifically for section-related methods in REMSaveRequest and REMStore
print("\n\n========================================")
print("SECTION-RELATED METHODS")
print("========================================")

if let saveRequestClass = NSClassFromString("REMSaveRequest") {
    print("\nREMSaveRequest section methods:")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(saveRequestClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.lowercased().contains("section") {
                print("  - \(name)")
            }
        }
        free(methods)
    }
}

if let storeClass = NSClassFromString("REMStore") {
    print("\nREMStore section methods:")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(storeClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.lowercased().contains("section") {
                print("  - \(name)")
            }
        }
        free(methods)
    }
}

if let listClass = NSClassFromString("REMList") {
    print("\nREMList section methods:")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(listClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.lowercased().contains("section") {
                print("  - \(name)")
            }
        }
        free(methods)
    }
}

if let listChangeItemClass = NSClassFromString("REMListChangeItem") {
    print("\nREMListChangeItem section methods:")
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(listChangeItemClass, &methodCount) {
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.lowercased().contains("section") {
                print("  - \(name)")
            }
        }
        free(methods)
    }
}

// Look for add/create methods in REMSaveRequest
print("\n\n========================================")
print("ADD/CREATE/INSERT METHODS IN REMSaveRequest")
print("========================================")

if let saveRequestClass = NSClassFromString("REMSaveRequest") {
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(saveRequestClass, &methodCount) {
        var methodNames: [String] = []
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            if name.lowercased().contains("add") || 
               name.lowercased().contains("create") ||
               name.lowercased().contains("insert") ||
               name.lowercased().contains("update") {
                methodNames.append(name)
            }
        }
        methodNames.sort()
        for name in methodNames {
            print("  - \(name)")
        }
        free(methods)
    }
}

print("\n✅ Investigation complete")
