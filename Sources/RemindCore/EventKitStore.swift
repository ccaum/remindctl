import EventKit
import Foundation

public actor RemindersStore {
  private let eventStore = EKEventStore()
  private let calendar: Calendar

  public init(calendar: Calendar = .current) {
    self.calendar = calendar
  }

  public func requestAccess() async throws {
    let status = Self.authorizationStatus()
    switch status {
    case .notDetermined:
      let updated = try await requestAuthorization()
      if updated != .fullAccess {
        throw RemindCoreError.accessDenied
      }
    case .denied, .restricted:
      throw RemindCoreError.accessDenied
    case .writeOnly:
      throw RemindCoreError.writeOnlyAccess
    case .fullAccess:
      break
    }
  }

  public static func authorizationStatus() -> RemindersAuthorizationStatus {
    RemindersAuthorizationStatus(eventKitStatus: EKEventStore.authorizationStatus(for: .reminder))
  }

  public func requestAuthorization() async throws -> RemindersAuthorizationStatus {
    let status = Self.authorizationStatus()
    switch status {
    case .notDetermined:
      let granted = try await requestFullAccess()
      return granted ? .fullAccess : .denied
    default:
      return status
    }
  }

  public func lists() async -> [ReminderList] {
    let subtaskStore = SubtaskStore()
    let sharingInfo = subtaskStore.fetchSharingInfo()
    
    return eventStore.calendars(for: .reminder).map { calendar in
      let info = sharingInfo[calendar.calendarIdentifier]
      return ReminderList(
        id: calendar.calendarIdentifier,
        title: calendar.title,
        isShared: info?.isShared,
        sharingStatus: info?.sharingStatus
      )
    }
  }

  public func defaultListName() -> String? {
    eventStore.defaultCalendarForNewReminders()?.title
  }

  public func reminders(in listName: String? = nil, includeSubtasks: Bool = false) async throws -> [ReminderItem] {
    let calendars: [EKCalendar]
    if let listName {
      calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
      if calendars.isEmpty {
        throw RemindCoreError.listNotFound(listName)
      }
    } else {
      calendars = eventStore.calendars(for: .reminder)
    }

    let items = await fetchReminders(in: calendars)
    
    if includeSubtasks {
        let subtaskStore = SubtaskStore()
        let subtaskInfo = subtaskStore.fetchSubtaskInfo()
        
        let enrichedItems = items.map { item -> ReminderItem in
            var newItem = item
            if let info = subtaskInfo[item.id] {
                newItem.parentID = info.parentID
                newItem.displayOrder = info.displayOrder
            }
            return newItem
        }
        
        // Build the tree
        var itemsByID = [String: ReminderItem]()
        for item in enrichedItems {
            itemsByID[item.id] = item
        }
        
        var topLevelItems = [ReminderItem]()
        for item in enrichedItems {
            if let parentID = item.parentID, var parent = itemsByID[parentID] {
                var subtasks = parent.subtasks ?? []
                subtasks.append(item)
                parent.subtasks = subtasks.sorted { ($0.displayOrder ?? 0) < ($1.displayOrder ?? 0) }
                itemsByID[parentID] = parent
            }
        }
        
        for item in enrichedItems {
            if item.parentID == nil {
                topLevelItems.append(itemsByID[item.id]!)
            }
        }
        
        return topLevelItems
    }
    
    return items
  }

  public func createList(name: String) async throws -> ReminderList {
    let list = EKCalendar(for: .reminder, eventStore: eventStore)
    list.title = name
    guard let source = eventStore.defaultCalendarForNewReminders()?.source else {
      throw RemindCoreError.operationFailed("Unable to determine default reminder source")
    }
    list.source = source
    try eventStore.saveCalendar(list, commit: true)
    return ReminderList(id: list.calendarIdentifier, title: list.title)
  }

  public func renameList(oldName: String, newName: String) async throws {
    let calendar = try calendar(named: oldName)
    guard calendar.allowsContentModifications else {
      throw RemindCoreError.operationFailed("Cannot modify system list")
    }
    calendar.title = newName
    try eventStore.saveCalendar(calendar, commit: true)
  }

  public func deleteList(name: String) async throws {
    let calendar = try calendar(named: name)
    guard calendar.allowsContentModifications else {
      throw RemindCoreError.operationFailed("Cannot delete system list")
    }
    try eventStore.removeCalendar(calendar, commit: true)
  }

  public func createReminder(_ draft: ReminderDraft, listName: String) async throws -> ReminderItem {
    let calendar = try calendar(named: listName)
    let reminder = EKReminder(eventStore: eventStore)
    reminder.title = draft.title
    reminder.notes = draft.notes
    reminder.calendar = calendar
    reminder.priority = draft.priority.eventKitValue
    if let dueDate = draft.dueDate {
      reminder.dueDateComponents = calendarComponents(from: dueDate)
    }
    try eventStore.save(reminder, commit: true)
    return ReminderItem(
      id: reminder.calendarItemIdentifier,
      title: reminder.title ?? "",
      notes: reminder.notes,
      isCompleted: reminder.isCompleted,
      completionDate: reminder.completionDate,
      priority: ReminderPriority(eventKitValue: Int(reminder.priority)),
      dueDate: date(from: reminder.dueDateComponents),
      listID: reminder.calendar.calendarIdentifier,
      listName: reminder.calendar.title
    )
  }

  public func updateReminder(id: String, update: ReminderUpdate) async throws -> ReminderItem {
    let reminder = try reminder(withID: id)

    if let title = update.title {
      reminder.title = title
    }
    if let notes = update.notes {
      reminder.notes = notes
    }
    if let dueDateUpdate = update.dueDate {
      if let dueDate = dueDateUpdate {
        reminder.dueDateComponents = calendarComponents(from: dueDate)
      } else {
        reminder.dueDateComponents = nil
      }
    }
    if let priority = update.priority {
      reminder.priority = priority.eventKitValue
    }
    if let listName = update.listName {
      reminder.calendar = try calendar(named: listName)
    }
    if let isCompleted = update.isCompleted {
      reminder.isCompleted = isCompleted
    }

    try eventStore.save(reminder, commit: true)

    return ReminderItem(
      id: reminder.calendarItemIdentifier,
      title: reminder.title ?? "",
      notes: reminder.notes,
      isCompleted: reminder.isCompleted,
      completionDate: reminder.completionDate,
      priority: ReminderPriority(eventKitValue: Int(reminder.priority)),
      dueDate: date(from: reminder.dueDateComponents),
      listID: reminder.calendar.calendarIdentifier,
      listName: reminder.calendar.title
    )
  }

  public func completeReminders(ids: [String]) async throws -> [ReminderItem] {
    var updated: [ReminderItem] = []
    for id in ids {
      let reminder = try reminder(withID: id)
      reminder.isCompleted = true
      try eventStore.save(reminder, commit: true)
      updated.append(
        ReminderItem(
          id: reminder.calendarItemIdentifier,
          title: reminder.title ?? "",
          notes: reminder.notes,
          isCompleted: reminder.isCompleted,
          completionDate: reminder.completionDate,
          priority: ReminderPriority(eventKitValue: Int(reminder.priority)),
          dueDate: date(from: reminder.dueDateComponents),
          listID: reminder.calendar.calendarIdentifier,
          listName: reminder.calendar.title
        )
      )
    }
    return updated
  }

  public func deleteReminders(ids: [String]) async throws -> Int {
    var deleted = 0
    for id in ids {
      let reminder = try reminder(withID: id)
      try eventStore.remove(reminder, commit: true)
      deleted += 1
    }
    return deleted
  }

  private func requestFullAccess() async throws -> Bool {
    try await withCheckedThrowingContinuation { continuation in
      eventStore.requestFullAccessToReminders { granted, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        continuation.resume(returning: granted)
      }
    }
  }

  private func fetchReminders(in calendars: [EKCalendar]) async -> [ReminderItem] {
    struct ReminderData: Sendable {
      let id: String
      let title: String
      let notes: String?
      let isCompleted: Bool
      let completionDate: Date?
      let priority: Int
      let dueDateComponents: DateComponents?
      let listID: String
      let listName: String
    }

    let reminderData = await withCheckedContinuation { (continuation: CheckedContinuation<[ReminderData], Never>) in
      let predicate = eventStore.predicateForReminders(in: calendars)
      eventStore.fetchReminders(matching: predicate) { reminders in
        let data = (reminders ?? []).map { reminder in
          ReminderData(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: Int(reminder.priority),
            dueDateComponents: reminder.dueDateComponents,
            listID: reminder.calendar.calendarIdentifier,
            listName: reminder.calendar.title
          )
        }
        continuation.resume(returning: data)
      }
    }

    return reminderData.map { data in
      ReminderItem(
        id: data.id,
        title: data.title,
        notes: data.notes,
        isCompleted: data.isCompleted,
        completionDate: data.completionDate,
        priority: ReminderPriority(eventKitValue: data.priority),
        dueDate: date(from: data.dueDateComponents),
        listID: data.listID,
        listName: data.listName
      )
    }
  }

  private func reminder(withID id: String) throws -> EKReminder {
    guard let item = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
      throw RemindCoreError.reminderNotFound(id)
    }
    return item
  }

  private func calendar(named name: String) throws -> EKCalendar {
    let calendars = eventStore.calendars(for: .reminder).filter { $0.title == name }
    guard let calendar = calendars.first else {
      throw RemindCoreError.listNotFound(name)
    }
    return calendar
  }

  private func calendarComponents(from date: Date) -> DateComponents {
    calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
  }

  private func date(from components: DateComponents?) -> Date? {
    guard let components else { return nil }
    return calendar.date(from: components)
  }

  private func item(from reminder: EKReminder) -> ReminderItem {
    ReminderItem(
      id: reminder.calendarItemIdentifier,
      title: reminder.title ?? "",
      notes: reminder.notes,
      isCompleted: reminder.isCompleted,
      completionDate: reminder.completionDate,
      priority: ReminderPriority(eventKitValue: Int(reminder.priority)),
      dueDate: date(from: reminder.dueDateComponents),
      listID: reminder.calendar.calendarIdentifier,
      listName: reminder.calendar.title
    )
  }
}
