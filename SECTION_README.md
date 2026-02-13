# Remindctl Section Support - Technical Analysis

## Summary

Section management via `remindctl` / `sectionctl` **WORKS** and has been verified to perform actual CRUD operations on Reminders.app sections.

## What Are Sections?

Sections are organizational groups within a reminder list. In Reminders.app, you can create sections to categorize reminders within a single list (e.g., "Work" section and "Personal" section within your "To-do" list).

## How Sections Work

1. **Database Level**: Sections are stored in `ZREMCDBASESECTION` table with:
   - `ZLIST` pointing to the parent list's Z_PK
   - `ZIDENTIFIER` containing the section's UUID
   - `ZDISPLAYNAME` containing the section name
   - `ZCKZONEOWNERNAME` for CloudKit sync (inherited from list)

2. **ReminderKit Private APIs**: Sections are managed via:
   - `REMListSection` - The section model class
   - `REMListSectionChangeItem` - Change item for modifications
   - `REMSaveRequest.addListSectionWithDisplayName:toListSectionContextChangeItem:` - Creates new sections
   - `REMSaveRequest.updateListSection:` - Gets change item for modifications
   - `REMListSectionChangeItem.removeFromList` - Marks section for deletion

3. **Reminders.app GUI**: Sections appear as collapsible groups within a list. Reminders can be assigned to sections.

## CLI Usage

### Using sectionctl directly

```bash
# List available reminder lists
./sectionctl lists

# Create a new section
./sectionctl create "To-do" "My Section"
./sectionctl create "7CB210F3-A578-477E-8CF0-0960B297836A" "My Section"

# List sections in a list
./sectionctl list "To-do"
./sectionctl list  # List all sections

# Update a section's display name
./sectionctl update "12345678-1234-1234-1234-123456789012" "New Name"

# Delete a section
./sectionctl delete "12345678-1234-1234-1234-123456789012"
```

### Using Python remindctl

```bash
# List available lists
python3 -m remindctl section lists

# Create a section
python3 -m remindctl section create --list-id "To-do" --display-name "My Section"

# List sections
python3 -m remindctl section list --list-id "To-do"

# Update a section
python3 -m remindctl section update --section-id "UUID" --display-name "New Name"

# Delete a section
python3 -m remindctl section delete --section-id "UUID"
```

## Critical Requirement: CloudKit-Synced Lists

**For sections to be properly visible and synced in Reminders.app, the list MUST be in an iCloud-synced list.**

### How to identify iCloud-synced lists:

Run `./sectionctl lists` and look for lists marked with `✅ iCloud`:
- ✅ "To-do" - CloudKit-synced, safe for sections
- ✅ "Silas Projects" - CloudKit-synced, safe for sections
- ⚠️ "Reminders" (default list) - May be local, sections may not sync properly

### Why this matters:

When a list is in a CloudKit-synced account:
1. The section inherits `ZCKZONEOWNERNAME` from the list
2. CloudKit properly syncs the section structure
3. Reminders.app displays sections correctly
4. Changes propagate to other devices

When a list is in a local-only account:
1. Sections may be created in the database
2. The section structure exists locally
3. BUT Reminders.app may not display it properly
4. Changes won't sync to other devices

## Verified Working Operations

All CRUD operations have been tested and verified (2024-02-13):

1. **Create** - ✅ Creates sections visible in database and Reminders.app
   - Creates sections with proper CloudKit sync metadata (`ZCKZONEOWNERNAME`)
   - Sections appear alongside existing sections in iCloud-synced lists
   - Verified: Created "⭐ OpenClaw Verification Section" in "Silas Projects" list
2. **List** - ✅ Lists all sections from database
   - Successfully reads sections from ZREMCDBASESECTION table
   - Shows section name, ID, and parent list ID
3. **Update** - ✅ Renames sections
   - Updates displayName via ReminderKit storage mechanism
   - Changes persist to database immediately
4. **Delete** - ✅ Removes sections from database
   - Uses `removeFromList` method on change item
   - Section properly marked for deletion and removed

## Implementation Details

### Create Section Flow

1. Load ReminderKit framework via `dlopen`
2. Create `REMStore` with user interactive mode
3. Create list object ID using `REMList.objectIDWithUUID:`
4. Fetch `REMList` using `fetchListWithObjectID:error:`
5. Create `REMSaveRequest` with store
6. Get list change item using `updateList:`
7. Get sections context using `sectionsContextChangeItem`
8. Create section using `addListSectionWithDisplayName:toListSectionContextChangeItem:`
9. Save using `saveSynchronouslyWithError:`

### Delete Section Flow

1. Load ReminderKit framework via `dlopen`
2. Create `REMStore` with user interactive mode
3. Create section object ID using `REMListSection.objectIDWithUUID:`
4. Fetch `REMListSection` using `fetchListSectionWithObjectID:error:`
5. Create `REMSaveRequest` with store
6. Get section change item using `updateListSection:`
7. Call `removeFromList` on the change item
8. Save using `saveSynchronouslyWithError:`

## Known Limitations

1. **AppleScript cannot access sections** - AppleScript API doesn't expose section information
2. **Sections in local-only lists** may not display correctly in GUI
3. **Section-to-reminder assignment** is not yet implemented in this tool (coming soon)

## Files

- `sectionctl.swift` - Swift binary for section operations
- `remindctl/commands/section.py` - Python CLI wrapper
- `SECTION_README.md` - This documentation

## Compilation

```bash
cd /path/to/remindctl
swiftc -o sectionctl sectionctl.swift -framework Foundation -framework Cocoa -framework EventKit -lsqlite3 -O
```
