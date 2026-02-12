import EventKit
import Foundation

public actor RemindersStore {
  let eventStore = EKEventStore()
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
    eventStore.calendars(for: .reminder).map { calendar in
      let sharingStatus = calendar.sharingStatusValue
      return ReminderList(
        id: calendar.calendarIdentifier,
        title: calendar.title,
        isShared: sharingStatus != 0,
        sharingStatus: sharingStatus
      )
    }
  }

  public func sharingInfo(for listName: String? = nil) async throws -> [ReminderListSharingInfo] {
    let calendars: [EKCalendar]
    if let listName {
      calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
      if calendars.isEmpty {
        throw RemindCoreError.listNotFound(listName)
      }
    } else {
      calendars = eventStore.calendars(for: .reminder)
    }

    return calendars.map { calendar in
      let sharingStatus = calendar.sharingStatusValue
      let isShared = sharingStatus != 0
      let canBeShared = calendar.canBeSharedValue
      
      // Determine if we are the owner. 
      // Research says if we are participant, sharees is nil and hasSharees is false.
      // Another way: check source.
      let isOwner = calendar.isOwnerValue
      
      var ownerName: String?
      var ownerEmail: String?
      
      if !isOwner {
        ownerName = calendar.sharedOwnerNameValue
        ownerEmail = calendar.sharedOwnerEmailValue
      }
      
      var sharees: [Sharee]?
      if isOwner && isShared {
        sharees = calendar.shareesValue?.compactMap { ekSharee in
          Sharee(
            name: ekSharee.ekShareeName,
            email: ekSharee.ekShareeEmail,
            accessLevel: ekSharee.accessLevelString,
            status: ekSharee.statusString
          )
        }
      }

      return ReminderListSharingInfo(
        listID: calendar.calendarIdentifier,
        listName: calendar.title,
        isShared: isShared,
        sharingStatus: sharingStatus,
        isOwner: isOwner,
        canBeShared: canBeShared,
        ownerName: ownerName,
        ownerEmail: ownerEmail,
        sharees: sharees
      )
    }
  }

  public func shareList(name: String, email: String, nameForSharee: String? = nil, readOnly: Bool = false) async throws {
    let calendar = try calendar(named: name)
    
    // Safety checks
    guard calendar.source?.sourceType == .calDAV || calendar.source?.sourceType == .subscribed else {
      throw RemindCoreError.operationFailed("Only iCloud lists can be shared")
    }
    
    guard calendar.canBeSharedValue else {
      throw RemindCoreError.operationFailed("This list cannot be shared")
    }
    
    guard calendar.isOwnerValue else {
      throw RemindCoreError.operationFailed("Only the owner can share this list")
    }

    // Create EKSharee
    guard let shareeClass = NSClassFromString("EKSharee") else {
      throw RemindCoreError.operationFailed("Sharing API not available on this macOS version")
    }
    
    let allocSel = NSSelectorFromString("alloc")
    let initSel = NSSelectorFromString("initWithName:url:")
    
    guard let alloced = (shareeClass as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject else {
      throw RemindCoreError.operationFailed("Failed to allocate EKSharee")
    }
    
    let emailURL = URL(string: "mailto:\(email)")! as NSURL
    let shareeName = (nameForSharee ?? email) as NSString
    
    guard let sharee = alloced.perform(initSel, with: shareeName, with: emailURL)?.takeUnretainedValue() as? NSObject else {
      throw RemindCoreError.operationFailed("Failed to initialize EKSharee")
    }
    
    // Set access level if needed (default is read-write, which is 2)
    // read-only is 1
    if readOnly {
        if sharee.responds(to: NSSelectorFromString("setShareeAccessLevel:")) {
            sharee.perform(NSSelectorFromString("setShareeAccessLevel:"), with: 1 as NSNumber)
        }
    }
    
    // Add sharee
    let addSel = NSSelectorFromString("addSharee:")
    guard calendar.responds(to: addSel) else {
      throw RemindCoreError.operationFailed("Calendar does not respond to addSharee:")
    }
    
    calendar.perform(addSel, with: sharee)
    
    try eventStore.saveCalendar(calendar, commit: true)
  }

  public func unshareList(name: String, email: String? = nil, all: Bool = false) async throws {
    let calendar = try calendar(named: name)
    
    guard calendar.isOwnerValue else {
      throw RemindCoreError.operationFailed("Only the owner can unshare this list")
    }

    if all {
      if let sharees = calendar.shareesValue {
        let removeSel = NSSelectorFromString("removeSharee:")
        for sharee in sharees {
          calendar.perform(removeSel, with: sharee)
        }
      }
    } else if let email = email {
      guard let sharees = calendar.shareesValue else {
        throw RemindCoreError.operationFailed("List has no sharees")
      }
      
      let targetSharee = sharees.first { $0.ekShareeEmail?.lowercased() == email.lowercased() }
      guard let shareeToRemove = targetSharee else {
        throw RemindCoreError.operationFailed("Sharee with email \(email) not found")
      }
      
      let removeSel = NSSelectorFromString("removeSharee:")
      calendar.perform(removeSel, with: shareeToRemove)
    }
    
    try eventStore.saveCalendar(calendar, commit: true)
  }

  public func defaultListName() -> String? {
    eventStore.defaultCalendarForNewReminders()?.title
  }

  public func reminders(in listName: String? = nil) async throws -> [ReminderItem] {
    let calendars: [EKCalendar]
    if let listName {
      calendars = eventStore.calendars(for: .reminder).filter { $0.title == listName }
      if calendars.isEmpty {
        throw RemindCoreError.listNotFound(listName)
      }
    } else {
      calendars = eventStore.calendars(for: .reminder)
    }

    return await fetchReminders(in: calendars)
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

  func reminder(withID id: String) throws -> EKReminder {
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

extension EKCalendar {
  var sharingStatusValue: Int {
    guard responds(to: NSSelectorFromString("sharingStatus")) else { return 0 }
    return (value(forKey: "sharingStatus") as? Int) ?? 0
  }

  var canBeSharedValue: Bool {
    guard responds(to: NSSelectorFromString("canBeShared")) else { return false }
    return (value(forKey: "canBeShared") as? Bool) ?? false
  }

  var isOwnerValue: Bool {
    if sharingStatusValue == 0 { return true }
    return canBeSharedValue
  }

  var sharedOwnerNameValue: String? {
    // skip for now as it crashes on frozen calendars
    return nil
  }

  var sharedOwnerEmailValue: String? {
    // skip for now as it crashes on frozen calendars
    return nil
  }

  var shareesValue: [NSObject]? {
    guard responds(to: NSSelectorFromString("sharees")) else { return nil }
    return value(forKey: "sharees") as? [NSObject]
  }
}

extension NSObject {
  var ekShareeName: String? {
    guard responds(to: NSSelectorFromString("name")) else { return nil }
    return value(forKey: "name") as? String
  }

  var ekShareeEmail: String? {
    guard responds(to: NSSelectorFromString("emailAddress")) else { return nil }
    return value(forKey: "emailAddress") as? String
  }

  var statusString: String {
    guard responds(to: NSSelectorFromString("shareeStatus")) else { return "unknown" }
    let status = (value(forKey: "shareeStatus") as? Int) ?? 0
    switch status {
    case 2: return "accepted"
    case 3: return "declined"
    case 5: return "pending"
    default: return "unknown"
    }
  }

  var accessLevelString: String {
    guard responds(to: NSSelectorFromString("shareeAccessLevel")) else { return "unknown" }
    let level = (value(forKey: "shareeAccessLevel") as? Int) ?? 0
    switch level {
    case 1: return "readOnly"
    case 2: return "readWrite"
    default: return "unknown"
    }
  }
}
