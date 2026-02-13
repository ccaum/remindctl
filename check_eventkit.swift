#!/usr/bin/env swift

import Foundation
import EventKit

let eventStore = EKEventStore()

// Request access
let semaphore = DispatchSemaphore(value: 0)
var accessGranted = false

eventStore.requestFullAccessToReminders { granted, error in
    accessGranted = granted
    semaphore.signal()
}
semaphore.wait()

guard accessGranted else {
    print("❌ Access denied")
    exit(1)
}

// Try to get specific reminders by ID
let testIDs = [
    "7675C894-E2B8-42C3-BB16-2035FCCDCE10",  // v3 approach2 subtask
    "154C736C-64C3-44D3-AD92-A3463827B9A4",  // parent
    "CF32472C-9DF1-457E-A4E1-EC34CAEF5194",  // original test subtask
    "F6A6FABD-E6B8-4433-BCC2-4AEA5482BA70",  // v1 subtask
]

for id in testIDs {
    if let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder {
        print("✅ \(id): \(item.title ?? "no title")")
    } else {
        print("❌ \(id): NOT FOUND via EventKit")
    }
}

// List all reminders and find ones with these IDs
print("\n--- Fetching all reminders ---")
let calendars = eventStore.calendars(for: .reminder)
let predicate = eventStore.predicateForReminders(in: calendars)

let fetchSemaphore = DispatchSemaphore(value: 0)
var allReminders: [EKReminder] = []

eventStore.fetchReminders(matching: predicate) { reminders in
    allReminders = reminders ?? []
    fetchSemaphore.signal()
}
fetchSemaphore.wait()

print("Total reminders via EventKit: \(allReminders.count)")

// Check if any of our test IDs are in the list
for id in testIDs {
    if let reminder = allReminders.first(where: { $0.calendarItemIdentifier == id }) {
        print("✅ Found \(id) in all reminders: \(reminder.title ?? "no title")")
    } else {
        print("❌ \(id) NOT in all reminders list")
    }
}
