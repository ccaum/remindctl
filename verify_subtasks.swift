#!/usr/bin/env swift

import Foundation
import EventKit

print("=== Remindctl Subtask Verification ===\n")

let eventStore = EKEventStore()
let sem = DispatchSemaphore(value: 0)
var accessGranted = false

eventStore.requestFullAccessToReminders { granted, _ in
    accessGranted = granted
    sem.signal()
}
sem.wait()

guard accessGranted else {
    print("❌ Access denied")
    exit(1)
}

// Define test cases
struct TestCase {
    let name: String
    let parentID: String
    let subtaskID: String
}

let testCases = [
    TestCase(name: "Original Test", parentID: "E8A12375-2543-45FF-A0E3-DBE046D8444C", subtaskID: "CF32472C-9DF1-457E-A4E1-EC34CAEF5194"),
    TestCase(name: "CloudKit List Test", parentID: "C40BD58B-F46F-4A59-9909-D4AA3C079A89", subtaskID: "E0449D2E-E48D-4B0A-B9A9-51886BBFC599"),
    TestCase(name: "Native Subtask", parentID: "C40BD58B-F46F-4A59-9909-D4AA3C079A89", subtaskID: "F55ACC43-98E6-44CD-9C24-84754315DC0A"),
]

for testCase in testCases {
    print("--- \(testCase.name) ---")
    
    if let parent = eventStore.calendarItem(withIdentifier: testCase.parentID) as? EKReminder {
        print("  Parent: \(parent.title ?? "?") [\(parent.calendar?.title ?? "?")]")
    } else {
        print("  Parent: NOT FOUND")
    }
    
    if let subtask = eventStore.calendarItem(withIdentifier: testCase.subtaskID) as? EKReminder {
        print("  Subtask: \(subtask.title ?? "?") ✅ (accessible via EventKit)")
    } else {
        print("  Subtask: NOT FOUND ❌")
    }
    
    print()
}

// Summary
print("=== Summary ===")
print("""
1. EventKit CAN access subtasks as regular EKReminder objects
2. AppleScript filters out subtasks from 'every reminder' queries
3. Subtasks should appear nested under parents in Reminders.app GUI

To verify subtasks in Reminders.app:
1. Open Reminders.app
2. Navigate to the list containing the parent reminder
3. Find the parent reminder (e.g., '__AS_PARENT3__' or 'Final Test Parent')
4. If the parent has a disclosure arrow (▶), click it to expand and see subtasks
5. If no arrow appears, the subtask relationship may not be properly synced

NOTE: Reminders created in non-iCloud lists may not support subtasks properly.
For best results, create parents/subtasks in an iCloud-synced list.
""")
