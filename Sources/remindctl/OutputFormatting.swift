import Foundation
import RemindCore

enum OutputFormat {
  case standard
  case plain
  case json
  case quiet
}

struct ListSummary: Codable, Sendable, Equatable {
  let id: String
  let title: String
  let reminderCount: Int
  let overdueCount: Int
  let isShared: Bool?
  let sharingStatus: Int?
}

struct ShareResult: Codable {
  let success: Bool
  let listName: String
  let sharedWith: SharedWithInfo
}

struct SharedWithInfo: Codable {
  let email: String
  let name: String?
  let accessLevel: String
  let status: String
}

struct UnshareResult: Codable {
  let success: Bool
  let listName: String
  let removed: RemovedInfo?
}

struct RemovedInfo: Codable {
  let email: String?
}

struct AuthorizationSummary: Codable, Sendable, Equatable {
  let status: String
  let authorized: Bool
}

enum OutputRenderer {
  static func printReminders(_ reminders: [ReminderItem], format: OutputFormat) {
    switch format {
    case .standard:
      printRemindersStandard(reminders)
    case .plain:
      printRemindersPlain(reminders)
    case .json:
      printJSON(reminders)
    case .quiet:
      Swift.print(reminders.count)
    }
  }

  static func printLists(_ summaries: [ListSummary], format: OutputFormat) {
    switch format {
    case .standard:
      printListsStandard(summaries)
    case .plain:
      printListsPlain(summaries)
    case .json:
      printJSON(summaries)
    case .quiet:
      Swift.print(summaries.count)
    }
  }

  static func printSharingInfo(_ info: [ReminderListSharingInfo], format: OutputFormat) {
    switch format {
    case .standard:
      printSharingInfoStandard(info)
    case .plain:
      printSharingInfoPlain(info)
    case .json:
      printJSON(info)
    case .quiet:
      break
    }
  }

  static func printShareResult(_ result: ShareResult, format: OutputFormat) {
    switch format {
    case .standard:
      Swift.print("✓ Sharing invitation sent to \(result.sharedWith.email) for \"\(result.listName)\"")
    case .plain:
      Swift.print("\(result.listName)\t\(result.sharedWith.email)\t\(result.sharedWith.name ?? "")\t\(result.sharedWith.accessLevel)")
    case .json:
      printJSON(result)
    case .quiet:
      break
    }
  }

  static func printUnshareResult(_ result: UnshareResult, format: OutputFormat) {
    switch format {
    case .standard:
      if let removed = result.removed, let email = removed.email {
        Swift.print("✓ Removed \(email) from \"\(result.listName)\"")
      } else {
        Swift.print("✓ \"\(result.listName)\" is no longer shared")
      }
    case .plain:
      Swift.print("\(result.listName)\t\(result.removed?.email ?? "all")")
    case .json:
      printJSON(result)
    case .quiet:
      break
    }
  }

  private static func printSharingInfoStandard(_ info: [ReminderListSharingInfo]) {
    for list in info {
      let statusText = list.isShared ? (list.isOwner ? "shared (you own this list)" : "shared") : "not shared"
      Swift.print("\(list.listName) — \(statusText)")

      if list.isShared && !list.isOwner {
        if let owner = list.ownerEmail {
          Swift.print("  Owner: \(owner)")
        }
        Swift.print("  You are a participant")
      } else if let sharees = list.sharees, !sharees.isEmpty {
        for sharee in sharees {
          let name = sharee.name ?? sharee.email ?? "Unknown"
          let email = sharee.email != nil ? " <\(sharee.email!)>" : ""
          Swift.print("  \(name)\(email) — \(sharee.accessLevel) (\(sharee.status))")
        }
      }
    }
  }

  private static func printSharingInfoPlain(_ info: [ReminderListSharingInfo]) {
    for list in info {
      let shareeCount = list.sharees?.count ?? 0
      Swift.print(
        "\(list.listName)\t\(list.isShared ? "1" : "0")\t\(list.isOwner ? "1" : "0")\t\(list.ownerEmail ?? "")\t\(shareeCount)"
      )
      if let sharees = list.sharees {
        for sharee in sharees {
          Swift.print("\t\(sharee.email ?? "")\t\(sharee.name ?? "")\t\(sharee.accessLevel)\t\(sharee.status)")
        }
      }
    }
  }

  static func printReminder(_ reminder: ReminderItem, format: OutputFormat) {
    switch format {
    case .standard:
      let due = reminder.dueDate.map { DateParsing.formatDisplay($0) } ?? "no due date"
      var extras: [String] = []
      if let section = reminder.section {
        extras.append("section:\(section)")
      }
      if let assigned = reminder.assigned {
        extras.append(assigned)
      }
      let extraStr = extras.isEmpty ? "" : " {\(extras.joined(separator: ", "))}"
      Swift.print("✓ \(reminder.title) [\(reminder.listName)] — \(due)\(extraStr)")
    case .plain:
      Swift.print(plainLine(for: reminder))
    case .json:
      printJSON(reminder)
    case .quiet:
      break
    }
  }

  static func printDeleteResult(_ count: Int, format: OutputFormat) {
    switch format {
    case .standard:
      Swift.print("Deleted \(count) reminder(s)")
    case .plain:
      Swift.print("\(count)")
    case .json:
      let payload = ["deleted": count]
      printJSON(payload)
    case .quiet:
      break
    }
  }

  static func printAuthorizationStatus(_ status: RemindersAuthorizationStatus, format: OutputFormat) {
    switch format {
    case .standard:
      Swift.print("Reminders access: \(status.displayName)")
    case .plain:
      Swift.print(status.rawValue)
    case .json:
      printJSON(AuthorizationSummary(status: status.rawValue, authorized: status.isAuthorized))
    case .quiet:
      Swift.print(status.isAuthorized ? "1" : "0")
    }
  }

  private static func printRemindersStandard(_ reminders: [ReminderItem]) {
    let sorted = ReminderFiltering.sort(reminders)
    guard !sorted.isEmpty else {
      Swift.print("No reminders found")
      return
    }
    
    var index = 1
    func printItem(_ item: ReminderItem, indent: Int = 0) {
      let status = item.isCompleted ? "x" : " "
      let due = item.dueDate.map { DateParsing.formatDisplay($0) } ?? "no due date"
      let priority = item.priority == .none ? "" : " priority=\(item.priority.rawValue)"
      let padding = String(repeating: " ", count: indent)
      let listPart = indent == 0 ? " [\(item.listName)]" : ""
      
      // Add section and assigned metadata hints
      var extras: [String] = []
      if let section = item.section {
        extras.append("§\(section)")
      }
      if let assigned = item.assigned {
        extras.append(assigned)
      }
      let extraStr = extras.isEmpty ? "" : " {\(extras.joined(separator: ", "))}"
      
      Swift.print("\(padding)[\(index)] [\(status)] \(item.title)\(listPart) — \(due)\(priority)\(extraStr)")
      index += 1
      
      if let subtasks = item.subtasks {
        for subtask in subtasks {
          printItem(subtask, indent: indent + 5)
        }
      }
    }
    
    for reminder in sorted {
      printItem(reminder)
    }
  }

  private static func printRemindersPlain(_ reminders: [ReminderItem]) {
    let sorted = ReminderFiltering.sort(reminders)
    func printItem(_ item: ReminderItem) {
      Swift.print(plainLine(for: item))
      if let subtasks = item.subtasks {
        for subtask in subtasks {
          printItem(subtask)
        }
      }
    }
    for item in sorted {
      printItem(item)
    }
  }

  private static func plainLine(for reminder: ReminderItem) -> String {
    let due = reminder.dueDate.map { isoFormatter().string(from: $0) } ?? ""
    return [
      reminder.id,
      reminder.listName,
      reminder.isCompleted ? "1" : "0",
      reminder.priority.rawValue,
      due,
      reminder.parentID ?? "",
      reminder.section ?? "",
      reminder.assigned ?? "",
      reminder.title,
    ].joined(separator: "\t")
  }

  private static func printListsStandard(_ summaries: [ListSummary]) {
    guard !summaries.isEmpty else {
      Swift.print("No reminder lists found")
      return
    }
    for summary in summaries.sorted(by: { $0.title < $1.title }) {
      let overdue = summary.overdueCount > 0 ? " (\(summary.overdueCount) overdue)" : ""
      Swift.print("\(summary.title) — \(summary.reminderCount) reminders\(overdue)")
    }
  }

  private static func printListsPlain(_ summaries: [ListSummary]) {
    for summary in summaries.sorted(by: { $0.title < $1.title }) {
      Swift.print("\(summary.title)\t\(summary.reminderCount)\t\(summary.overdueCount)")
    }
  }

  static func printJSON<T: Encodable>(_ payload: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(payload)
      if let json = String(data: data, encoding: .utf8) {
        Swift.print(json)
      }
    } catch {
      Swift.print("Failed to encode JSON: \(error)")
    }
  }

  private static func isoFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }
}
