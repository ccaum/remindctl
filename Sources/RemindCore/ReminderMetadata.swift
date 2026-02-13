import Foundation

/// Metadata parsed from reminder notes.
/// Stores section and assignment information using tag patterns like:
/// `[section:Groceries]` and `[assigned:@bob]`
public struct ReminderMetadata: Codable, Sendable, Equatable {
    /// The section name (e.g., "Groceries")
    public var section: String?
    
    /// The assignee (e.g., "@bob")
    public var assigned: String?
    
    public init(section: String? = nil, assigned: String? = nil) {
        self.section = section
        self.assigned = assigned
    }
    
    /// Returns true if there is any metadata
    public var isEmpty: Bool {
        section == nil && assigned == nil
    }
}

// MARK: - Tag Patterns

/// Namespace for metadata parsing utilities
public enum MetadataParser {
    
    // Tag patterns: [section:NAME] and [assigned:@NAME]
    private static let sectionPattern = #"\[section:([^\]]+)\]"#
    private static let assignedPattern = #"\[assigned:(@[^\]]+)\]"#
    
    // Compiled regex (lazy)
    private static let sectionRegex = try! NSRegularExpression(pattern: sectionPattern, options: [])
    private static let assignedRegex = try! NSRegularExpression(pattern: assignedPattern, options: [])
    
    /// Parse metadata from a notes string
    /// - Parameter notes: The notes field of a reminder
    /// - Returns: Parsed metadata
    public static func parse(from notes: String?) -> ReminderMetadata {
        guard let notes = notes, !notes.isEmpty else {
            return ReminderMetadata()
        }
        
        let range = NSRange(notes.startIndex..., in: notes)
        
        var section: String?
        if let match = sectionRegex.firstMatch(in: notes, options: [], range: range),
           let sectionRange = Range(match.range(at: 1), in: notes) {
            section = String(notes[sectionRange])
        }
        
        var assigned: String?
        if let match = assignedRegex.firstMatch(in: notes, options: [], range: range),
           let assignedRange = Range(match.range(at: 1), in: notes) {
            assigned = String(notes[assignedRange])
        }
        
        return ReminderMetadata(section: section, assigned: assigned)
    }
    
    /// Update notes with new metadata values
    /// - Parameters:
    ///   - notes: Original notes string (can be nil)
    ///   - section: New section value (nil to remove, .some(nil) to clear, .some(value) to set)
    ///   - assigned: New assigned value (nil to remove, .some(nil) to clear, .some(value) to set)
    /// - Returns: Updated notes string
    public static func updateNotes(
        _ notes: String?,
        section: String?? = nil,
        assigned: String?? = nil
    ) -> String {
        var result = notes ?? ""
        
        // Handle section
        if let sectionUpdate = section {
            // Remove existing section tag
            let range = NSRange(result.startIndex..., in: result)
            result = sectionRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
            
            // Add new section tag if value provided
            if let newSection = sectionUpdate, !newSection.isEmpty {
                let tag = "[section:\(newSection)]"
                result = appendTag(tag, to: result)
            }
        }
        
        // Handle assigned
        if let assignedUpdate = assigned {
            // Remove existing assigned tag
            let range = NSRange(result.startIndex..., in: result)
            result = assignedRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
            
            // Add new assigned tag if value provided
            if let newAssigned = assignedUpdate, !newAssigned.isEmpty {
                // Ensure @ prefix
                let assignee = newAssigned.hasPrefix("@") ? newAssigned : "@\(newAssigned)"
                let tag = "[assigned:\(assignee)]"
                result = appendTag(tag, to: result)
            }
        }
        
        // Clean up extra whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Normalize multiple spaces/newlines
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        
        return result
    }
    
    /// Strip metadata tags from notes (return clean user content)
    public static func stripMetadata(from notes: String?) -> String? {
        guard let notes = notes, !notes.isEmpty else {
            return nil
        }
        
        var result = notes
        let range = NSRange(result.startIndex..., in: result)
        
        result = sectionRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        let newRange = NSRange(result.startIndex..., in: result)
        result = assignedRegex.stringByReplacingMatches(in: result, options: [], range: newRange, withTemplate: "")
        
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return result.isEmpty ? nil : result
    }
    
    /// Append a tag to notes, adding to a metadata line at the end
    private static func appendTag(_ tag: String, to notes: String) -> String {
        if notes.isEmpty {
            return tag
        }
        
        // Check if the last line already contains metadata tags
        let lines = notes.components(separatedBy: "\n")
        if let lastLine = lines.last,
           lastLine.contains("[section:") || lastLine.contains("[assigned:") {
            // Append to same line
            var modifiedLines = lines
            modifiedLines[modifiedLines.count - 1] = lastLine + " " + tag
            return modifiedLines.joined(separator: "\n")
        } else {
            // Add new line with tag
            return notes + "\n" + tag
        }
    }
    
    /// Extract all unique section names from an array of reminders
    public static func extractSections(from reminders: [ReminderItem]) -> [String] {
        var sections = Set<String>()
        for reminder in reminders {
            let metadata = parse(from: reminder.notes)
            if let section = metadata.section {
                sections.insert(section)
            }
        }
        return Array(sections).sorted()
    }
    
    /// Extract all unique assignees from an array of reminders
    public static func extractAssignees(from reminders: [ReminderItem]) -> [String] {
        var assignees = Set<String>()
        for reminder in reminders {
            let metadata = parse(from: reminder.notes)
            if let assigned = metadata.assigned {
                assignees.insert(assigned)
            }
        }
        return Array(assignees).sorted()
    }
    
    /// Filter reminders by section
    public static func filter(_ reminders: [ReminderItem], bySection section: String) -> [ReminderItem] {
        reminders.filter { reminder in
            let metadata = parse(from: reminder.notes)
            return metadata.section?.lowercased() == section.lowercased()
        }
    }
    
    /// Filter reminders by assignee
    public static func filter(_ reminders: [ReminderItem], byAssigned assigned: String) -> [ReminderItem] {
        let normalizedAssigned = assigned.hasPrefix("@") ? assigned : "@\(assigned)"
        return reminders.filter { reminder in
            let metadata = parse(from: reminder.notes)
            return metadata.assigned?.lowercased() == normalizedAssigned.lowercased()
        }
    }
}
