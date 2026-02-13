# Remindctl Subtask Support - Technical Analysis

## Summary

Subtask creation via `remindctl` / `subtaskctl` **WORKS** - but with an important caveat about list types.

## How Subtasks Work

1. **Database Level**: Subtasks are stored as regular reminders with:
   - `ZPARENTREMINDER` pointing to the parent's Z_PK
   - `ZCKPARENTREMINDERIDENTIFIER` containing the parent's UUID
   - All other reminder fields

2. **EventKit API**: EventKit returns **ALL reminders including subtasks** as `EKReminder` objects. Subtasks are indistinguishable from regular reminders at this level.

3. **AppleScript API**: AppleScript **intentionally filters out subtasks** from `every reminder` queries. This is by design - subtasks should be accessed through their parent.

4. **Reminders.app GUI**: Subtasks appear **nested under their parent** with a disclosure arrow (▶). They don't appear as standalone items in the flat list view.

## Critical Requirement: CloudKit-Synced Lists

**For subtasks to be visible in Reminders.app, the parent reminder MUST be in an iCloud-synced list.**

### How to identify iCloud-synced lists:

Lists with `ZCKZONEOWNERNAME` populated in the database are CloudKit-synced. Examples:
- ✅ "Silas Projects" - Has CloudKit zone owner
- ✅ "To-do" - Has CloudKit zone owner  
- ❌ "Reminders" (default list) - May be local/migrated without full CloudKit integration

### Why this matters:

When a parent is in a CloudKit-synced list:
1. The subtask inherits `ZCKZONEOWNERNAME` from the parent/list
2. CloudKit properly syncs the parent-child relationship
3. Reminders.app displays the disclosure arrow on the parent
4. Clicking the parent reveals nested subtasks

When a parent is in a local/non-CloudKit list:
1. The subtask has empty `ZCKZONEOWNERNAME`
2. The parent-child relationship exists in the database
3. EventKit can access both parent and subtask
4. BUT Reminders.app may not display the disclosure arrow

## Verification Commands

```bash
# Check if a subtask is accessible via EventKit
cd /Users/openclaw/.openclaw/workspace-coding/remindctl
swift verify_subtasks.swift

# List subtasks for a parent (reads from database)
./subtaskctl list <parent-id>

# Check CloudKit sync status for a reminder
sqlite3 ~/Library/Group\ Containers/group.com.apple.reminders/Container_v1/Stores/Data-*.sqlite \
  "SELECT ZTITLE, ZCKZONEOWNERNAME FROM ZREMCDREMINDER WHERE ZDACALENDARITEMUNIQUEIDENTIFIER = '<uuid>';"
```

## Solution for Visibility Issues

1. **Ensure the parent is in an iCloud-synced list** before creating subtasks
2. **Use the "To-do" or other user-created lists** instead of the default "Reminders" list
3. **Wait a few seconds** after creation for CloudKit sync to complete
4. **Look for the disclosure arrow** (▶) on the parent reminder in Reminders.app

## Verified Working Test Case

```bash
# Parent in CloudKit-synced list "Silas Projects"
./subtaskctl create "C40BD58B-F46F-4A59-9909-D4AA3C079A89" "My Subtask"

# This subtask IS visible in Reminders.app under "Final Test Parent"
```

## Known Limitations

1. **AppleScript cannot enumerate subtasks** - This is an Apple limitation
2. **Local-only lists may not support subtask visibility** in the GUI
3. **Newly created subtasks may take 1-2 seconds** to appear in the GUI after CloudKit sync
