import Commander
import Foundation
import RemindCore

enum ShareesCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "sharees",
      abstract: "Show sharing status and participants",
      discussion: "Omit list name to show sharing status for all lists.",
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "list-name", help: "List name", isOptional: true)
          ]
        )
      ),
      usageExamples: [
        "remindctl sharees",
        "remindctl sharees Groceries",
        "remindctl sharees --json",
      ]
    ) { values, runtime in
      let listName = values.argument(0)

      let store = RemindersStore()
      try await store.requestAccess()

      let sharingInfo = try await store.sharingInfo(for: listName)
      OutputRenderer.printSharingInfo(sharingInfo, format: runtime.outputFormat)
    }
  }
}
