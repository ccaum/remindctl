import Commander
import Foundation
import RemindCore

private struct SectionSummary: Encodable {
  let name: String
  let count: Int
}

enum SectionsCommand {
  static var spec: CommandSpec {
    CommandSpec(
      name: "sections",
      abstract: "List unique section names from reminders",
      discussion: """
        Lists all unique section names found in reminder notes metadata.
        Sections are stored as [section:NAME] tags in reminder notes.
        
        Use --list to filter by a specific list.
        Use --count to show reminder counts per section.
        """,
      signature: CommandSignatures.withRuntimeFlags(
        CommandSignature(
          arguments: [],
          options: [
            .make(label: "list", names: [.short("l"), .long("list")], help: "Filter by list name", parsing: .singleValue),
          ],
          flags: [
            .make(label: "count", names: [.short("c"), .long("count")], help: "Show reminder count per section"),
          ]
        )
      ),
      usageExamples: [
        "remindctl sections",
        "remindctl sections --list \"Shopping\"",
        "remindctl sections --count",
        "remindctl sections --json",
      ]
    ) { values, runtime in
      let store = RemindersStore()
      try await store.requestAccess()
      
      let listName = values.option("list")
      let showCount = values.flag("count")
      
      let reminders = try await store.reminders(in: listName)
      
      if showCount {
        // Group by section and count
        var sectionCounts: [String: Int] = [:]
        for reminder in reminders {
          let metadata = MetadataParser.parse(from: reminder.notes)
          if let section = metadata.section {
            sectionCounts[section, default: 0] += 1
          }
        }
        
        let summaries = sectionCounts.map { SectionSummary(name: $0.key, count: $0.value) }
          .sorted { $0.name < $1.name }
        
        switch runtime.outputFormat {
        case .json:
          OutputRenderer.printJSON(summaries)
        case .standard:
          if summaries.isEmpty {
            Swift.print("No sections found")
          } else {
            Swift.print("Sections:")
            for summary in summaries {
              Swift.print("  \(summary.name) (\(summary.count) reminder\(summary.count == 1 ? "" : "s"))")
            }
          }
        case .plain:
          for summary in summaries {
            Swift.print("\(summary.name)\t\(summary.count)")
          }
        case .quiet:
          Swift.print(summaries.count)
        }
      } else {
        // Just list unique section names
        let sections = MetadataParser.extractSections(from: reminders)
        
        switch runtime.outputFormat {
        case .json:
          OutputRenderer.printJSON(sections)
        case .standard:
          if sections.isEmpty {
            Swift.print("No sections found")
          } else {
            Swift.print("Sections:")
            for section in sections {
              Swift.print("  \(section)")
            }
          }
        case .plain:
          for section in sections {
            Swift.print(section)
          }
        case .quiet:
          Swift.print(sections.count)
        }
      }
    }
  }
}
