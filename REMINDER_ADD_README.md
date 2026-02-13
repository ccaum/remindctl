# remindctl add - Add Reminders with Section Support

## Overview

The `remindctl add` command allows you to create reminders in specific lists and target them for specific sections. Due to macOS limitations, full automatic section assignment is not currently supported, but the tool provides a practical workaround.

## Usage

### Add reminder to a list

```bash
python3 -m remindctl add "My Reminder" --list "To-do"
python3 -m remindctl add "My Reminder" --list-id "7CB210F3-A578-477E-8CF0-0960B297836A"
```

### Add reminder targeting a section

```bash
python3 -m remindctl add "My Reminder" --section "Misc"
python3 -m remindctl add "My Reminder" --section-id "EC2FA675-4B05-4022-A22C-2DB61D827B8A"
```

When targeting a section:
1. The reminder is created in the section's parent list
2. A note marker `[Section: <name>]` is added to the reminder's notes
3. The output provides instructions for manual section assignment

### Direct Swift binary usage

```bash
./reminderctl add "My Reminder" --list "To-do"
./reminderctl add "My Reminder" --section "Misc"
```

## Available Sections

To see available sections:

```bash
./sectionctl list
# or
python3 -m remindctl section list
```

## Technical Limitations

### Why automatic section assignment doesn't work

Apple's ReminderKit framework stores section memberships in a special data structure (`ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA`) on the list itself. While the private API provides methods to modify this:

- `REMListSectionContextChangeItem.setUnsavedMembershipsOfRemindersInSections:`

Attempts to use these methods consistently crash the `remindd` daemon with error:
- **Error Code**: 4099 (NSXPCConnectionInterrupted)
- **Description**: "Couldn't communicate with a helper application"

This appears to be either:
1. A deliberate security measure in macOS
2. Additional undocumented requirements for using this API
3. A bug in the current macOS version

### Workaround

The tool creates reminders in the correct list and adds a note marker (`[Section: <name>]`) to help with manual organization. Users can then:

1. Open Reminders.app
2. Navigate to the target list and section
3. Drag the reminder into the appropriate section

### What works

- ✅ Creating reminders in lists
- ✅ Creating sections
- ✅ Managing section metadata (rename, delete)
- ✅ Listing sections
- ✅ Adding notes to reminders
- ✅ Creating subtasks (via `subtaskctl`)

### What doesn't work

- ❌ Automatic section assignment during reminder creation
- ❌ Moving existing reminders to sections programmatically

## Files

- `reminderctl.swift` - Swift binary for reminder creation with section targeting
- `remindctl/commands/add.py` - Python CLI wrapper
- `sectionctl.swift` - Section CRUD operations (create, list, update, delete)

## Compilation

```bash
cd /path/to/remindctl
swiftc -o reminderctl reminderctl.swift -framework Foundation -framework Cocoa -framework EventKit -lsqlite3 -O
```

## Future Work

If Apple provides public APIs for section management, or if the private API behavior changes, this tool can be updated to support automatic section assignment. The infrastructure for tracking memberships is already in place.
