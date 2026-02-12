import Commander
import Foundation
import RemindCore

enum ShareCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "share",
      abstract: "Share a list with someone (experimental)",
      discussion: "Uses private EventKit APIs. Use with caution.",
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "list-name", help: "List name")
          ],
          options: [
            .make(
              label: "email",
              names: [.short("e"), .long("email")],
              help: "Email address to share with",
              parsing: .singleValue
            ),
            .make(
              label: "name",
              names: [.long("name")],
              help: "Display name for the sharee",
              parsing: .singleValue
            )
          ],
          flags: [
            .make(label: "read-only", names: [.long("read-only")], help: "Share with read-only access"),
            .make(label: "force", names: [.short("f"), .long("force")], help: "Skip confirmation prompts")
          ]
        )
      ),
      usageExamples: [
        "remindctl share Groceries --email partner@icloud.com",
        "remindctl share Groceries --email friend@icloud.com --read-only",
      ]
    ) { values, runtime in
      let listName = values.argument(0)!
      guard let email = values.option("email") else {
        throw RemindCoreError.operationFailed("Email address is required. Use --email <email>")
      }
      let name = values.option("name")
      let readOnly = values.flag("read-only")
      let force = values.flag("force")

      if !force && !runtime.noInput && Console.isTTY {
        Swift.print("⚠️  Sharing uses private Apple APIs (may break in future macOS updates).")
        if !Console.confirm("Share \"\(listName)\" with \(email) (\(readOnly ? "read-only" : "read-write"))?", defaultValue: false) {
          return
        }
      }

      let store = RemindersStore()
      try await store.requestAccess()

      try await store.shareList(name: listName, email: email, nameForSharee: name, readOnly: readOnly)

      OutputRenderer.printShareResult(
        ShareResult(
          success: true,
          listName: listName,
          sharedWith: SharedWithInfo(
            email: email,
            name: name,
            accessLevel: readOnly ? "readOnly" : "readWrite",
            status: "pending"
          )
        ),
        format: runtime.outputFormat
      )
    }
  }
}
