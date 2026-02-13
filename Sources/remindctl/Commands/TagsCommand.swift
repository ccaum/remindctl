import Commander
import Foundation
import RemindCore

private struct TagActionResult: Encodable {
  let action: String
  let tag: String
  let tags: [String]
}

enum TagsCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "tags",
      abstract: "Manage tags on a reminder",
      discussion: """
        Native Reminders.app tags. Tags appear in the Reminders tag browser
        and can be used for filtering across all lists.
        
        Usage:
          remindctl tags <reminder-id>              List tags
          remindctl tags add <tag> to <reminder-id>     Add a tag
          remindctl tags remove <tag> from <reminder-id>  Remove a tag
        """,
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "action-or-id", help: "Action (add/remove) or reminder ID", isOptional: false),
            .make(label: "tag", help: "Tag name (without #)", isOptional: true),
            .make(label: "to-from", help: "'to' or 'from' keyword", isOptional: true),
            .make(label: "reminder-id", help: "Reminder ID", isOptional: true),
          ]
        )
      ),
      usageExamples: [
        "remindctl tags <reminder-id>",
        "remindctl tags add urgent to <reminder-id>",
        "remindctl tags remove urgent from <reminder-id>",
      ]
    ) { values, runtime in
      let store = RemindersStore()
      try await store.requestAccess()
      
      let positionals = values.positional
      guard !positionals.isEmpty else {
        throw ParsedValuesError.missingArgument("action-or-id")
      }
      
      let firstArg = positionals[0]
      
      switch firstArg.lowercased() {
      case "add":
        try await handleAdd(positionals: positionals, store: store, runtime: runtime)
      case "remove":
        try await handleRemove(positionals: positionals, store: store, runtime: runtime)
      default:
        // Treat first arg as reminder ID for listing
        try await handleList(reminderID: firstArg, store: store, runtime: runtime)
      }
    }
  }
  
  private static func handleList(reminderID: String, store: RemindersStore, runtime: RuntimeOptions) async throws {
    // Resolve the ID first
    let reminders = try await store.reminders(in: nil)
    let resolved = try IDResolver.resolve([reminderID], from: reminders)
    guard let reminder = resolved.first else {
      throw RemindCoreError.reminderNotFound(reminderID)
    }
    
    let tags = try await store.tags(for: reminder.id)
    if runtime.outputFormat == .json {
      OutputRenderer.printJSON(tags)
    } else {
      if tags.isEmpty {
        Swift.print("No tags")
      } else {
        for tag in tags {
          Swift.print(tag)
        }
      }
    }
  }
  
  private static func handleAdd(positionals: [String], store: RemindersStore, runtime: RuntimeOptions) async throws {
    // Expected: add <tag> to <reminder-id>
    guard positionals.count >= 4 else {
      throw RemindCoreError.operationFailed("Usage: remindctl tags add <tag> to <reminder-id>")
    }
    
    let tag = positionals[1]
    let keyword = positionals[2].lowercased()
    let reminderInput = positionals[3]
    
    guard keyword == "to" else {
      throw RemindCoreError.operationFailed("Expected 'to' keyword. Usage: remindctl tags add <tag> to <reminder-id>")
    }
    
    // Resolve the ID
    let reminders = try await store.reminders(in: nil)
    let resolved = try IDResolver.resolve([reminderInput], from: reminders)
    guard let reminder = resolved.first else {
      throw RemindCoreError.reminderNotFound(reminderInput)
    }
    
    try await store.addTag(tag, to: reminder.id)
    
    let updatedTags = try await store.tags(for: reminder.id)
    if runtime.outputFormat == .json {
      OutputRenderer.printJSON(TagActionResult(action: "added", tag: tag, tags: updatedTags))
    } else {
      Swift.print("Added tag: \(tag)")
    }
  }
  
  private static func handleRemove(positionals: [String], store: RemindersStore, runtime: RuntimeOptions) async throws {
    // Expected: remove <tag> from <reminder-id>
    guard positionals.count >= 4 else {
      throw RemindCoreError.operationFailed("Usage: remindctl tags remove <tag> from <reminder-id>")
    }
    
    let tag = positionals[1]
    let keyword = positionals[2].lowercased()
    let reminderInput = positionals[3]
    
    guard keyword == "from" else {
      throw RemindCoreError.operationFailed("Expected 'from' keyword. Usage: remindctl tags remove <tag> from <reminder-id>")
    }
    
    // Resolve the ID
    let reminders = try await store.reminders(in: nil)
    let resolved = try IDResolver.resolve([reminderInput], from: reminders)
    guard let reminder = resolved.first else {
      throw RemindCoreError.reminderNotFound(reminderInput)
    }
    
    try await store.removeTag(tag, from: reminder.id)
    
    let updatedTags = try await store.tags(for: reminder.id)
    if runtime.outputFormat == .json {
      OutputRenderer.printJSON(TagActionResult(action: "removed", tag: tag, tags: updatedTags))
    } else {
      Swift.print("Removed tag: \(tag)")
    }
  }
}
