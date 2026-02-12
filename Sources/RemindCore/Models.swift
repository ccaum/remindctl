import Foundation

public enum ReminderPriority: String, Codable, CaseIterable, Sendable {
  case none
  case low
  case medium
  case high

  public init(eventKitValue: Int) {
    switch eventKitValue {
    case 1...4:
      self = .high
    case 5:
      self = .medium
    case 6...9:
      self = .low
    default:
      self = .none
    }
  }

  public var eventKitValue: Int {
    switch self {
    case .none:
      return 0
    case .high:
      return 1
    case .medium:
      return 5
    case .low:
      return 9
    }
  }
}

public struct ReminderList: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let isShared: Bool
  public let sharingStatus: Int

  public init(id: String, title: String, isShared: Bool = false, sharingStatus: Int = 0) {
    self.id = id
    self.title = title
    self.isShared = isShared
    self.sharingStatus = sharingStatus
  }
}

public struct Sharee: Codable, Sendable, Equatable {
  public let name: String?
  public let email: String?
  public let accessLevel: String // readOnly, readWrite, unknown
  public let status: String // pending, accepted, declined, unknown

  public init(name: String?, email: String?, accessLevel: String, status: String) {
    self.name = name
    self.email = email
    self.accessLevel = accessLevel
    self.status = status
  }
}

public struct ReminderListSharingInfo: Codable, Sendable, Equatable {
  public let listID: String
  public let listName: String
  public let isShared: Bool
  public let sharingStatus: Int
  public let isOwner: Bool
  public let canBeShared: Bool
  public let ownerName: String?
  public let ownerEmail: String?
  public let sharees: [Sharee]?

  public init(
    listID: String,
    listName: String,
    isShared: Bool,
    sharingStatus: Int,
    isOwner: Bool,
    canBeShared: Bool,
    ownerName: String? = nil,
    ownerEmail: String? = nil,
    sharees: [Sharee]? = nil
  ) {
    self.listID = listID
    self.listName = listName
    self.isShared = isShared
    self.sharingStatus = sharingStatus
    self.isOwner = isOwner
    self.canBeShared = canBeShared
    self.ownerName = ownerName
    self.ownerEmail = ownerEmail
    self.sharees = sharees
  }
}

public struct ReminderItem: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let notes: String?
  public let isCompleted: Bool
  public let completionDate: Date?
  public let priority: ReminderPriority
  public let dueDate: Date?
  public let listID: String
  public let listName: String

  public init(
    id: String,
    title: String,
    notes: String?,
    isCompleted: Bool,
    completionDate: Date?,
    priority: ReminderPriority,
    dueDate: Date?,
    listID: String,
    listName: String
  ) {
    self.id = id
    self.title = title
    self.notes = notes
    self.isCompleted = isCompleted
    self.completionDate = completionDate
    self.priority = priority
    self.dueDate = dueDate
    self.listID = listID
    self.listName = listName
  }
}

public struct ReminderDraft: Sendable {
  public let title: String
  public let notes: String?
  public let dueDate: Date?
  public let priority: ReminderPriority

  public init(title: String, notes: String?, dueDate: Date?, priority: ReminderPriority) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
  }
}

public struct ReminderUpdate: Sendable {
  public let title: String?
  public let notes: String?
  public let dueDate: Date??
  public let priority: ReminderPriority?
  public let listName: String?
  public let isCompleted: Bool?

  public init(
    title: String? = nil,
    notes: String? = nil,
    dueDate: Date?? = nil,
    priority: ReminderPriority? = nil,
    listName: String? = nil,
    isCompleted: Bool? = nil
  ) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
    self.listName = listName
    self.isCompleted = isCompleted
  }
}
