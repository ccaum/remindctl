# remindctl add - Add Reminders with Section Support

## Overview

The `remindctl add` command allows you to create reminders in specific lists and **directly assign them to sections**. Section assignment is now fully supported!

## ✅ Section Assignment Works!

Reminders created with `--section` will automatically appear under the specified section in Reminders.app. No manual dragging required.

## Usage

### Add reminder to a list

```bash
./reminderctl add "My Reminder" --list "To-do"
./reminderctl add "My Reminder" --list-id "7CB210F3-A578-477E-8CF0-0960B297836A"
```

### Add reminder to a section (RECOMMENDED)

```bash
# By section name
./reminderctl add "My Task" --section "Misc"
./reminderctl add "Workout reminder" --section "Fitness App"

# By section UUID
./reminderctl add "My Task" --section "EC2FA675-4B05-4022-A22C-2DB61D827B8A"
```

When using `--section`:
1. The reminder is automatically created in the section's parent list
2. The reminder is automatically assigned to the specified section
3. The reminder appears **immediately** under that section in Reminders.app GUI

### Add reminder with notes

```bash
./reminderctl add "My Task" --section "Misc" --notes "This is my note"
```

## Available Commands

```bash
./reminderctl add <title> --list <listID|listName>       # Create in list
./reminderctl add <title> --section <sectionID|name>     # Create in section ✅
./reminderctl lists                                       # Show available lists
./reminderctl sections [listID|listName]                  # Show sections
```

## Examples

```bash
# Create reminder in "Misc" section
./reminderctl add "Buy groceries" --section "Misc"

# Create reminder in "Fitness App" section with notes
./reminderctl add "Morning workout" --section "Fitness App" --notes "Start with stretching"

# List all sections in "Silas Projects"
./reminderctl sections "Silas Projects"
```

## Technical Details

### How Section Assignment Works

Section assignment uses Apple's private `ReminderKit.framework` with the following key classes:

1. **REMMembership** - Represents a reminder-to-section relationship
   - `memberIdentifier`: The reminder's UUID
   - `groupIdentifier`: The section's UUID  
   - `modifiedOn`: Timestamp

2. **REMMemberships** - A container for membership objects (critical!)
   - Using `NSSet` directly **crashes** `remindd`
   - The `REMMemberships` wrapper class is required for stable operation

3. **REMListSectionContextChangeItem** - Manages section memberships
   - `setUnsavedMembershipsOfRemindersInSections:` sets the membership data

### Key Discovery

The critical insight that made section assignment work was discovering that `setUnsavedMembershipsOfRemindersInSections:` expects an `REMMemberships` object, not a plain `NSSet`. The property type in the Objective-C runtime shows `@property unsavedMembershipsOfRemindersInSections [T@"REMMemberships",&,N]`.

### Database Storage

Section memberships are stored in the `ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA` column of `ZREMCDBASELIST` as JSON:

```json
{
  "minimumSupportedVersion": 20230430,
  "memberships": [
    {
      "memberID": "REMINDER-UUID",
      "groupID": "SECTION-UUID",
      "modifiedOn": 792712734.564943
    }
  ]
}
```

## Requirements

- macOS with iCloud-synced Reminders lists
- Full disk access for the executable
- Reminders app permission granted

## Files

- `reminderctl` - Compiled binary
- `reminderctl.swift` - Swift source with working section assignment
- `sectionctl.swift` - Section CRUD operations (create, list, update, delete)

## Compilation

```bash
cd /path/to/remindctl
swiftc -o reminderctl reminderctl.swift -framework Foundation -framework Cocoa -framework EventKit -lsqlite3 -O
```

## Verification

After creating a reminder with `--section`, you can verify the assignment:

1. Open Reminders.app
2. Navigate to the specified list
3. Expand the section - your reminder should be there

Or use the database verification:

```bash
./verify_section  # Shows all section memberships
```
