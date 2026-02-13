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
  public let isShared: Bool?
  public let sharingStatus: Int?

  public init(id: String, title: String, isShared: Bool? = nil, sharingStatus: Int? = nil) {
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
  public var parentID: String?
  public var subtasks: [ReminderItem]?
  public var displayOrder: Int?
  
  /// Section name parsed from notes metadata (e.g., [section:Groceries])
  public var section: String?
  
  /// Assignee parsed from notes metadata (e.g., [assigned:@bob])
  public var assigned: String?

  public init(
    id: String,
    title: String,
    notes: String?,
    isCompleted: Bool,
    completionDate: Date?,
    priority: ReminderPriority,
    dueDate: Date?,
    listID: String,
    listName: String,
    parentID: String? = nil,
    subtasks: [ReminderItem]? = nil,
    displayOrder: Int? = nil,
    section: String? = nil,
    assigned: String? = nil
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
    self.parentID = parentID
    self.subtasks = subtasks
    self.displayOrder = displayOrder
    self.section = section
    self.assigned = assigned
  }
  
  /// Returns a copy with metadata fields populated from notes
  public func withParsedMetadata() -> ReminderItem {
    let metadata = MetadataParser.parse(from: notes)
    var copy = self
    copy.section = metadata.section
    copy.assigned = metadata.assigned
    return copy
  }
}

public struct ReminderDraft: Sendable {
  public let title: String
  public let notes: String?
  public let dueDate: Date?
  public let priority: ReminderPriority
  public let parentID: String?
  
  /// Section name to add to notes metadata
  public let section: String?
  
  /// Assignee to add to notes metadata
  public let assigned: String?

  public init(
    title: String,
    notes: String?,
    dueDate: Date?,
    priority: ReminderPriority,
    parentID: String? = nil,
    section: String? = nil,
    assigned: String? = nil
  ) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
    self.parentID = parentID
    self.section = section
    self.assigned = assigned
  }
  
  /// Returns notes with metadata tags included
  public func notesWithMetadata() -> String? {
    var result = notes
    
    if section != nil || assigned != nil {
      result = MetadataParser.updateNotes(
        result,
        section: section.map { .some($0) },
        assigned: assigned.map { .some($0) }
      )
    }
    
    return result?.isEmpty == true ? nil : result
  }
}

public struct ReminderUpdate: Sendable {
  public let title: String?
  public let notes: String?
  public let dueDate: Date??
  public let priority: ReminderPriority?
  public let listName: String?
  public let isCompleted: Bool?
  public let parentID: String??
  public let sectionID: String??
  
  /// Section name to set in notes metadata (.some(nil) to clear)
  public let section: String??
  
  /// Assignee to set in notes metadata (.some(nil) to clear)
  public let assigned: String??

  public init(
    title: String? = nil,
    notes: String? = nil,
    dueDate: Date?? = nil,
    priority: ReminderPriority? = nil,
    listName: String? = nil,
    isCompleted: Bool? = nil,
    parentID: String?? = nil,
    sectionID: String?? = nil,
    section: String?? = nil,
    assigned: String?? = nil
  ) {
    self.title = title
    self.notes = notes
    self.dueDate = dueDate
    self.priority = priority
    self.listName = listName
    self.isCompleted = isCompleted
    self.parentID = parentID
    self.sectionID = sectionID
    self.section = section
    self.assigned = assigned
  }
}

// MARK: - Section Models

public struct SectionItem: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let listID: String
  public let listName: String

  public init(id: String, displayName: String, listID: String, listName: String) {
    self.id = id
    self.displayName = displayName
    self.listID = listID
    self.listName = listName
  }
}

public struct SectionMembership: Codable, Sendable {
  public let memberID: String
  public let groupID: String
  public let modifiedOn: Double

  public init(memberID: String, groupID: String, modifiedOn: Double = Date().timeIntervalSinceReferenceDate) {
    self.memberID = memberID
    self.groupID = groupID
    self.modifiedOn = modifiedOn
  }
}

public struct SectionMembershipsData: Codable, Sendable {
  public let minimumSupportedVersion: Int
  public var memberships: [SectionMembership]

  public init(minimumSupportedVersion: Int = 20230430, memberships: [SectionMembership] = []) {
    self.minimumSupportedVersion = minimumSupportedVersion
    self.memberships = memberships
  }
}
