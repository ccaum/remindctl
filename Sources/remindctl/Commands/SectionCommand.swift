import Commander
import Foundation
import RemindCore

enum SectionCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "section",
      abstract: "Manage sections within lists",
      discussion: """
        Sections are visual groupings within a list.
        
        Subcommands:
          list <list>     List all sections in a list
          add <name>      Add a section to a list
          delete <id>     Delete a section
          assign <id>     Assign a reminder to a section
        """,
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "action", help: "Action: list, add, delete, assign"),
            .make(label: "value", help: "Section name, ID, or list name", isOptional: true)
          ],
          options: [
            .make(label: "list", names: [.short("l"), .long("list")], help: "List name", parsing: .singleValue),
            .make(label: "reminder", names: [.short("r"), .long("reminder")], help: "Reminder ID (for assign)", parsing: .singleValue),
            .make(label: "section", names: [.short("s"), .long("section")], help: "Section ID (for assign)", parsing: .singleValue),
          ],
          flags: [
            .make(label: "remove", names: [.long("remove")], help: "Remove reminder from its section"),
          ]
        )
      ),
      usageExamples: [
        "remindctl section list --list \"My List\"",
        "remindctl section add \"Work Tasks\" --list \"Projects\"",
        "remindctl section delete ABC123 --list \"Projects\"",
        "remindctl section assign --reminder REM123 --section SEC456",
        "remindctl section assign --reminder REM123 --remove",
      ]
    ) { values, runtime in
      guard let action = values.argument(0) else {
        throw RemindCoreError.operationFailed("Missing action. Use: list, add, delete, or assign")
      }
      
      switch action.lowercased() {
      case "list", "ls":
        try await listSections(values: values, runtime: runtime)
      case "add", "create":
        try await addSection(values: values, runtime: runtime)
      case "delete", "rm", "remove":
        try await deleteSection(values: values, runtime: runtime)
      case "assign", "move":
        try await assignSection(values: values, runtime: runtime)
      default:
        throw RemindCoreError.operationFailed("Unknown action '\(action)'. Use: list, add, delete, or assign")
      }
    }
  }
  
  private static func listSections(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let listName = values.argument(1) ?? values.option("list")
    
    guard let listName else {
      throw RemindCoreError.operationFailed("Missing list name. Use: section list <list-name> or --list <list-name>")
    }
    
    let store = RemindersStore()
    try await store.requestAccess()
    
    // Get list ID from name
    let lists = await store.lists()
    guard let list = lists.first(where: { $0.title == listName }) else {
      throw RemindCoreError.listNotFound(listName)
    }
    
    let sectionStore = SectionStore()
    let sections = sectionStore.fetchSections(forListID: list.id)
    
    switch runtime.outputFormat {
    case .json:
      OutputRenderer.printJSON(sections)
    case .standard:
      if sections.isEmpty {
        Swift.print("No sections found in '\(listName)'")
      } else {
        Swift.print("Sections in '\(listName)':")
        for section in sections {
          Swift.print("  • \(section.displayName)  (\(section.id))")
        }
      }
    case .plain:
      for section in sections {
        Swift.print("\(section.id)\t\(section.displayName)\t\(section.listID)\t\(section.listName)")
      }
    case .quiet:
      Swift.print(sections.count)
    }
  }
  
  private static func addSection(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let sectionName = values.argument(1)
    let listName = values.option("list")
    
    guard let sectionName else {
      throw RemindCoreError.operationFailed("Missing section name. Use: section add <section-name> --list <list-name>")
    }
    
    guard let listName else {
      throw RemindCoreError.operationFailed("Missing list name. Use --list <list-name>")
    }
    
    let store = RemindersStore()
    try await store.requestAccess()
    
    let section = try await store.createSection(displayName: sectionName, listName: listName)
    
    switch runtime.outputFormat {
    case .json:
      OutputRenderer.printJSON(section)
    case .standard:
      Swift.print("✓ Created section '\(section.displayName)' in '\(section.listName)'")
      Swift.print("  Section ID: \(section.id)")
    case .plain:
      Swift.print("\(section.id)\t\(section.displayName)\t\(section.listID)\t\(section.listName)")
    case .quiet:
      break
    }
  }
  
  private static func deleteSection(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let sectionID = values.argument(1)
    let listName = values.option("list")
    
    guard let sectionID else {
      throw RemindCoreError.operationFailed("Missing section ID. Use: section delete <section-id> --list <list-name>")
    }
    
    guard let listName else {
      throw RemindCoreError.operationFailed("Missing list name. Use --list <list-name>")
    }
    
    let store = RemindersStore()
    try await store.requestAccess()
    
    try await store.deleteSection(sectionID: sectionID, listName: listName)
    
    switch runtime.outputFormat {
    case .json:
      OutputRenderer.printJSON(["deleted": sectionID])
    case .standard:
      Swift.print("✓ Deleted section \(sectionID)")
    case .plain:
      Swift.print(sectionID)
    case .quiet:
      break
    }
  }
  
  private static func assignSection(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let reminderID = values.option("reminder")
    let sectionID = values.option("section")
    let removeFromSection = values.flag("remove")
    
    guard let reminderID else {
      throw RemindCoreError.operationFailed("Missing reminder ID. Use --reminder <id>")
    }
    
    if !removeFromSection && sectionID == nil {
      throw RemindCoreError.operationFailed("Missing section ID. Use --section <id> or --remove")
    }
    
    let store = RemindersStore()
    try await store.requestAccess()
    
    let targetSectionID = removeFromSection ? nil : sectionID
    try await store.moveReminderToSection(reminderID: reminderID, sectionID: targetSectionID)
    
    switch runtime.outputFormat {
    case .json:
      struct AssignResult: Codable {
        let reminder: String
        let section: String?
      }
      OutputRenderer.printJSON(AssignResult(reminder: reminderID, section: targetSectionID))
    case .standard:
      if let sectionID = targetSectionID {
        Swift.print("✓ Moved reminder \(reminderID) to section \(sectionID)")
      } else {
        Swift.print("✓ Removed reminder \(reminderID) from its section")
      }
    case .plain:
      Swift.print("\(reminderID)\t\(targetSectionID ?? "")")
    case .quiet:
      break
    }
  }
}
