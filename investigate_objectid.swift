#!/usr/bin/env swift

import Foundation
import Cocoa

// Load ReminderKit
let paths = [
    "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit",
    "/System/Library/PrivateFrameworks/ReminderKitInternal.framework/ReminderKitInternal"
]

for path in paths {
    dlopen(path, RTLD_NOW | RTLD_GLOBAL)
}

// Look at REMObjectID
if let objectIDClass = NSClassFromString("REMObjectID") {
    print("=== REMObjectID ===")
    
    // Instance methods
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(objectIDClass, &methodCount) {
        print("\nInstance Methods:")
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            print("  - \(name)")
        }
        free(methods)
    }
    
    // Class methods
    if let metaClass = object_getClass(objectIDClass) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
            print("\nClass Methods:")
            for i in 0..<Int(classMethodCount) {
                let method = classMethods[i]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                print("  + \(name)")
            }
            free(classMethods)
        }
    }
} else {
    print("REMObjectID not found")
}

// Check REMListObjectID
if let listObjectIDClass = NSClassFromString("REMListObjectID") {
    print("\n=== REMListObjectID ===")
    
    // Instance methods
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(listObjectIDClass, &methodCount) {
        print("\nInstance Methods:")
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            print("  - \(name)")
        }
        free(methods)
    }
    
    // Class methods
    if let metaClass = object_getClass(listObjectIDClass) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
            print("\nClass Methods:")
            for i in 0..<Int(classMethodCount) {
                let method = classMethods[i]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                print("  + \(name)")
            }
            free(classMethods)
        }
    }
} else {
    print("\nREMListObjectID not found")
}

// Check REMListSectionObjectID
if let sectionObjectIDClass = NSClassFromString("REMListSectionObjectID") {
    print("\n=== REMListSectionObjectID ===")
    
    // Instance methods
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(sectionObjectIDClass, &methodCount) {
        print("\nInstance Methods:")
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = method_getName(method)
            let name = NSStringFromSelector(selector)
            print("  - \(name)")
        }
        free(methods)
    }
    
    // Class methods
    if let metaClass = object_getClass(sectionObjectIDClass) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
            print("\nClass Methods:")
            for i in 0..<Int(classMethodCount) {
                let method = classMethods[i]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                print("  + \(name)")
            }
            free(classMethods)
        }
    }
} else {
    print("\nREMListSectionObjectID not found")
}

// Check REMList
if let listClass = NSClassFromString("REMList") {
    print("\n=== REMList class methods ===")
    
    if let metaClass = object_getClass(listClass) {
        var classMethodCount: UInt32 = 0
        if let classMethods = class_copyMethodList(metaClass, &classMethodCount) {
            print("\nClass Methods:")
            for i in 0..<Int(classMethodCount) {
                let method = classMethods[i]
                let selector = method_getName(method)
                let name = NSStringFromSelector(selector)
                print("  + \(name)")
            }
            free(classMethods)
        }
    }
} else {
    print("\nREMList not found")
}

print("\n✅ Done")
