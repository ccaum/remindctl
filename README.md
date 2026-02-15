# remindctl

Forget the app, not the task ✅

Fast CLI for Apple Reminders on macOS.

## Install

### Homebrew (Home Pro)
```bash
brew install steipete/tap/remindctl
```

### From source
```bash
pnpm install
pnpm build
# binary at ./bin/remindctl
```

## Development
```bash
make remindctl ARGS="status"   # clean build + run
make check                     # lint + test + coverage gate
```

## Requirements
- macOS 14+ (Sonoma or later)
- Swift 6.2+
- Reminders permission (System Settings → Privacy & Security → Reminders)

## Usage
```bash
remindctl                      # show today (default)
remindctl today                 # show today
remindctl tomorrow              # show tomorrow
remindctl week                  # show this week
remindctl overdue               # overdue
remindctl upcoming              # upcoming
remindctl completed             # completed
remindctl all                   # all reminders
remindctl 2026-01-03            # specific date

remindctl list                  # lists
remindctl list Work             # show list
remindctl list Work --rename Office
remindctl list Work --delete
remindctl list Projects --create

remindctl add "Buy milk"
remindctl add --title "Call mom" --list Personal --due tomorrow
remindctl edit 1 --title "New title" --due 2026-01-04
remindctl complete 1 2 3
remindctl delete 4A83 --force
remindctl status                # permission status
remindctl authorize             # request permissions

# subtasks
remindctl add "Subtask" --parent <parent-id>
remindctl edit 5 --clear-parent

# tags
remindctl tags <reminder-id>
remindctl tags add urgent to <reminder-id>
remindctl tags remove urgent from <reminder-id>

# sections
remindctl section list --list "My List"
remindctl section add "Work Tasks" --list "Projects"
remindctl section assign --reminder <id> --section <section-id>
```

## Output formats
- `--json` emits JSON arrays/objects.
- `--plain` emits tab-separated lines.
- `--quiet` emits counts only.

## Date formats
Accepted by `--due` and filters:
- `today`, `tomorrow`, `yesterday`
- `YYYY-MM-DD`
- `YYYY-MM-DD HH:mm`
- ISO 8601 (`2026-01-03T12:34:56Z`)

## Permissions
Run `remindctl authorize` to trigger the system prompt. If access is denied, enable
Terminal (or remindctl) in System Settings → Privacy & Security → Reminders.
If running over SSH, grant access on the Mac that runs the command.

## Subtasks
Create hierarchical reminders using the `--parent` flag. Subtasks appear nested under their parent in Reminders.app.

### Creating subtasks
```bash
# Create a subtask under an existing reminder
remindctl add "Buy eggs" --parent <parent-id>
remindctl add "Buy bread" --parent <parent-id> --list Shopping

# The parent ID comes from reminder output (use --json to see full IDs)
remindctl list Shopping --json | jq '.[0].id'
```

### Managing parent relationships
```bash
# Move a reminder under a different parent
remindctl edit <reminder-id> --parent <new-parent-id>

# Remove from parent (make it a top-level reminder)
remindctl edit <reminder-id> --clear-parent
```

### Constraints
- Parent and child must be in the **same list**
- Subtasks sync across devices via iCloud
- Subtask depth is limited by Reminders.app (typically 1 level)
- When viewing reminders, subtasks appear nested under their parent in JSON output

## Tags
Native Reminders.app tags that sync across devices. Tags appear in the Reminders tag browser and can be used for filtering across all lists.

### Listing tags
```bash
# List all tags on a reminder
remindctl tags <reminder-id>
remindctl tags 1                    # using index
remindctl tags 4A83                 # using ID prefix
```

### Adding tags
```bash
remindctl tags add urgent to <reminder-id>
remindctl tags add work to 1
remindctl tags add "high priority" to 4A83    # tags with spaces
```

### Removing tags
```bash
remindctl tags remove urgent from <reminder-id>
remindctl tags remove work from 1
```

### Constraints
- Tags are **case-insensitive** in Reminders.app
- Tags sync across all Apple devices via iCloud
- Tags without the `#` prefix (just use `urgent`, not `#urgent`)
- Empty tags are not allowed

## Sections
Sections provide visual grouping within lists. remindctl supports two types:

### Native Sections
macOS Reminders sections that appear as collapsible groups in Reminders.app.

```bash
# List sections in a list
remindctl section list --list "My List"
remindctl section list "My List"              # positional also works

# Create a new section
remindctl section add "Work Tasks" --list "Projects"

# Delete a section
remindctl section delete <section-id> --list "Projects"

# Assign a reminder to a section
remindctl section assign --reminder <reminder-id> --section <section-id>

# Remove a reminder from its section
remindctl section assign --reminder <reminder-id> --remove
```

### Metadata Sections
Lightweight section tags stored in reminder notes. Useful for quick categorization without managing native sections.

```bash
# Add with a metadata section
remindctl add "Buy milk" --section Groceries

# Set/change section on existing reminder
remindctl edit 1 --section "Work Tasks"

# Remove section metadata
remindctl edit 1 --clear-section

# List all unique metadata sections
remindctl sections
remindctl sections --list Shopping
remindctl sections --count              # show reminder counts
```

### When to use which
| Feature | Native Sections | Metadata Sections |
|---------|----------------|-------------------|
| Visible in Reminders.app | ✅ Collapsible groups | ❌ Only in notes |
| iCloud sync | ✅ Requires iCloud list | ✅ Via notes field |
| Setup complexity | Higher (create first) | Lower (just tag) |
| Use case | Permanent structure | Quick categorization |

### Constraints
- **Native sections** require the list to be synced via iCloud
- Native sections can only be created on lists you own (not shared lists you're a member of)
- **Metadata sections** are stored as `[section:NAME]` in the notes field—editing notes directly may affect them
- A reminder can belong to one native section and have one metadata section simultaneously
