# remindctl/commands/add.py
"""Add reminder command for remindctl."""

import subprocess
import os


def run_add_cmd(args):
    """Execute the reminderctl binary with add arguments."""
    # Determine the path to the compiled reminderctl binary
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    reminderctl_path = os.path.join(project_root, "reminderctl")

    if not os.path.exists(reminderctl_path):
        raise FileNotFoundError(
            f"reminderctl binary not found at {reminderctl_path}. "
            "Make sure to compile reminderctl.swift first."
        )

    # Build command
    cmd_parts = [reminderctl_path, "add", args.title]
    
    if args.section_id:
        cmd_parts.extend(["--section", args.section_id])
    elif args.list_id:
        cmd_parts.extend(["--list", args.list_id])
    else:
        raise ValueError("Either --section or --list must be specified")

    try:
        result = subprocess.run(cmd_parts, capture_output=True, text=True, check=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
    except subprocess.CalledProcessError as e:
        print(f"Error running reminderctl: {e}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        raise
    except FileNotFoundError as e:
        print(f"Error: {e}. Make sure 'reminderctl' is compiled and accessible.")
        raise


def add_parser(subparsers):
    """Register the add subparser."""
    ap = subparsers.add_parser("add", help="Add a new reminder")
    ap.add_argument(
        "title",
        help="Title of the reminder"
    )
    ap.add_argument(
        "--section", "--section-id",
        dest="section_id",
        help="Section ID or name to add the reminder to"
    )
    ap.add_argument(
        "--list", "--list-id",
        dest="list_id",
        help="List ID or name to add the reminder to (if not using --section)"
    )
    ap.set_defaults(func=run_add_cmd)
