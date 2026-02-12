import Commander
import Foundation
import RemindCore

enum TagsCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "tags",
      abstract: "List tags on a reminder",
      discussion: "Shows all hashtags used in the reminder's notes.",
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "reminder-id", help: "ID of the reminder")
          ]
        )
      ),
      usageExamples: ["remindctl tags <reminder-id>"]
    ) { values, runtime in
      let reminderID = values.argument(0)!
      let store = RemindersStore()
      try await store.requestAccess()
      let tags = try await store.tags(for: reminderID)
      if runtime.outputFormat == .json {
        OutputRenderer.printJSON(tags)
      } else {
        for tag in tags { Swift.print(tag) }
      }
    }
  }
}
