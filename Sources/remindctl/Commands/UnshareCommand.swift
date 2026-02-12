import Commander
import Foundation
import RemindCore

enum UnshareCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "unshare",
      abstract: "Remove a sharee or stop sharing entirely",
      discussion: "Uses private EventKit APIs.",
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "list-name", help: "List name")
          ],
          options: [
            .make(
              label: "email",
              names: [.short("e"), .long("email")],
              help: "Email of the sharee to remove",
              parsing: .singleValue
            )
          ],
          flags: [
            .make(label: "all", names: [.long("all")], help: "Remove all sharees"),
            .make(label: "force", names: [.short("f"), .long("force")], help: "Skip confirmation prompts")
          ]
        )
      ),
      usageExamples: [
        "remindctl unshare Groceries --email friend@icloud.com",
        "remindctl unshare Groceries --all",
      ]
    ) { values, runtime in
      let listName = values.argument(0)!
      let email = values.option("email")
      let all = values.flag("all")
      let force = values.flag("force")

      if email == nil && !all {
        throw RemindCoreError.operationFailed("Either --email or --all is required")
      }
      if email != nil && all {
        throw RemindCoreError.operationFailed("--email and --all are mutually exclusive")
      }

      if !force && !runtime.noInput && Console.isTTY {
        let message = all ? "Stop sharing \"\(listName)\" with all participants?" : "Remove \(email!) from \"\(listName)\"?"
        if !Console.confirm(message, defaultValue: false) {
          return
        }
      }

      let store = RemindersStore()
      try await store.requestAccess()

      try await store.unshareList(name: listName, email: email, all: all)

      OutputRenderer.printUnshareResult(
        UnshareResult(
          success: true,
          listName: listName,
          removed: email.map { RemovedInfo(email: $0) }
        ),
        format: runtime.outputFormat
      )
    }
  }
}
