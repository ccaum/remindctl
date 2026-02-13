import Commander
import Foundation
import RemindCore

private struct AssigneeSummary: Encodable {
  let assignee: String
  let count: Int
}

enum AssignedCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "assigned",
      abstract: "List reminders by assignee",
      discussion: """
        Lists reminders filtered by assignee, or lists all unique assignees.
        Assignees are stored as [assigned:@NAME] tags in reminder notes.
        
        Without arguments, lists all unique assignees.
        With an assignee argument (e.g., @bob), lists reminders assigned to that person.
        """,
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [
            .make(label: "assignee", help: "Assignee to filter by (e.g., @bob)", isOptional: true)
          ],
          options: [
            .make(label: "list", names: [.short("l"), .long("list")], help: "Filter by list name", parsing: .singleValue),
          ],
          flags: [
            .make(label: "count", names: [.short("c"), .long("count")], help: "Show reminder count per assignee"),
          ]
        )
      ),
      usageExamples: [
        "remindctl assigned",
        "remindctl assigned @bob",
        "remindctl assigned --count",
        "remindctl assigned @alice --list \"Work\"",
        "remindctl assigned --json",
      ]
    ) { values, runtime in
      let store = RemindersStore()
      try await store.requestAccess()
      
      let listName = values.option("list")
      let showCount = values.flag("count")
      let assigneeFilter = values.argument(0)
      
      let reminders = try await store.reminders(in: listName)
      
      if let assignee = assigneeFilter {
        // Filter reminders by assignee
        let filtered = MetadataParser.filter(reminders, byAssigned: assignee)
        OutputRenderer.printReminders(filtered, format: runtime.outputFormat)
      } else if showCount {
        // Group by assignee and count
        var assigneeCounts: [String: Int] = [:]
        for reminder in reminders {
          let metadata = MetadataParser.parse(from: reminder.notes)
          if let assigned = metadata.assigned {
            assigneeCounts[assigned, default: 0] += 1
          }
        }
        
        let summaries = assigneeCounts.map { AssigneeSummary(assignee: $0.key, count: $0.value) }
          .sorted { $0.assignee < $1.assignee }
        
        switch runtime.outputFormat {
        case .json:
          OutputRenderer.printJSON(summaries)
        case .standard:
          if summaries.isEmpty {
            Swift.print("No assignees found")
          } else {
            Swift.print("Assignees:")
            for summary in summaries {
              Swift.print("  \(summary.assignee) (\(summary.count) reminder\(summary.count == 1 ? "" : "s"))")
            }
          }
        case .plain:
          for summary in summaries {
            Swift.print("\(summary.assignee)\t\(summary.count)")
          }
        case .quiet:
          Swift.print(summaries.count)
        }
      } else {
        // Just list unique assignees
        let assignees = MetadataParser.extractAssignees(from: reminders)
        
        switch runtime.outputFormat {
        case .json:
          OutputRenderer.printJSON(assignees)
        case .standard:
          if assignees.isEmpty {
            Swift.print("No assignees found")
          } else {
            Swift.print("Assignees:")
            for assignee in assignees {
              Swift.print("  \(assignee)")
            }
          }
        case .plain:
          for assignee in assignees {
            Swift.print(assignee)
          }
        case .quiet:
          Swift.print(assignees.count)
        }
      }
    }
  }
}
