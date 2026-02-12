import EventKit
import Foundation

extension RemindersStore {
  // Extract tags from notes (hashtags)
  private func extractTags(from notes: String?) -> [String] {
    guard let notes else { return [] }
    // Simple regex to capture words starting with # without spaces
    let pattern = "#([A-Za-z0-9_]+)"
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: [])
      let matches = regex.matches(in: notes, options: [], range: NSRange(notes.startIndex..., in: notes))
      return matches.compactMap { match in
        if let range = Range(match.range(at: 1), in: notes) {
          return String(notes[range])
        }
        return nil
      }
    } catch {
      return []
    }
  }

  public func tags(for reminderID: String) async throws -> [String] {
    let item = try reminder(withID: reminderID)
    return extractTags(from: item.notes)
  }

  public func addTag(_ tag: String, to reminderID: String) async throws {
    let item = try reminder(withID: reminderID)
    var tags = Set(extractTags(from: item.notes))
    guard !tags.contains(tag) else { return }
    tags.insert(tag)
    // Append tag to notes
    let notes = item.notes ?? ""
    let newNotes = notes.isEmpty ? "#\(tag)" : "\(notes) #\(tag)"
    item.notes = newNotes
    try eventStore.save(item, commit: true)
  }

  public func removeTag(_ tag: String, from reminderID: String) async throws {
    let item = try reminder(withID: reminderID)
    var tags = Set(extractTags(from: item.notes))
    guard tags.contains(tag) else { return }
    tags.remove(tag)
    // Remove tag from notes
    var notes = item.notes ?? ""
    // Replace exact hashtag token (case-sensitive)
    let pattern = "\\s?#\\b" + NSRegularExpression.escapedPattern(for: tag) + "\\b"
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: [])
      notes = regex.stringByReplacingMatches(in: notes, options: [], range: NSRange(notes.startIndex..., in: notes), withTemplate: "")
    } catch { }
    item.notes = notes.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    try eventStore.save(item, commit: true)
  }
}
