import Commander
import Foundation
import RemindCore

enum ShowCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "show",
      abstract: "Show reminders",
      discussion: "Filters: today, tomorrow, week, overdue, upcoming, completed, all, or a date string.",
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(
              label: "filter",
              help: "today|tomorrow|week|overdue|upcoming|completed|all|<date>",
              isOptional: true
            )
          ],
          options: [
            .make(
              label: "list",
              names: [.short("l"), .long("list")],
              help: "Limit to a specific list",
              parsing: .singleValue
            )
          ],
          flags: [
            .make(
              label: "subtasks",
              names: [.short("s"), .long("subtasks")],
              help: "Show subtasks nested under their parents"
            )
          ]
        )
      ),
      usageExamples: [
        "remindctl",
        "remindctl today",
        "remindctl show overdue",
        "remindctl show 2026-01-04",
        "remindctl show --list Work",
        "remindctl show --subtasks",
      ]
    ) { values, runtime in
      let listName = values.option("list")
      let showSubtasks = values.flag("subtasks")
      let filterToken = values.argument(0)

      let filter: ReminderFilter
      if let token = filterToken {
        guard let parsed = ReminderFiltering.parse(token) else {
          throw RemindCoreError.operationFailed("Unknown filter: \"\(token)\"")
        }
        filter = parsed
      } else {
        filter = .today
      }

      let store = RemindersStore()
      try await store.requestAccess()
      let reminders = try await store.reminders(in: listName, includeSubtasks: showSubtasks)
      
      let filtered: [ReminderItem]
      if showSubtasks {
          // If showing subtasks, we only apply filter to top-level items
          filtered = ReminderFiltering.apply(reminders, filter: filter)
      } else {
          filtered = ReminderFiltering.apply(reminders, filter: filter)
      }
      
      OutputRenderer.printReminders(filtered, format: runtime.outputFormat)
    }
  }
}
