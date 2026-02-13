# remindctl/commands/section.py
"""Section management commands for remindctl."""

import subprocess
import os


def run_section_cmd(args):
    """Execute the sectionctl binary with the given arguments."""
    # Determine the path to the compiled sectionctl binary
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    sectionctl_path = os.path.join(project_root, "sectionctl")

    if not os.path.exists(sectionctl_path):
        # Fallback: check if it's in the same directory as the package
        package_dir = os.path.dirname(script_dir)
        sectionctl_path = os.path.join(package_dir, "sectionctl")
        
    if not os.path.exists(sectionctl_path):
        raise FileNotFoundError(
            f"sectionctl binary not found. Expected at {os.path.join(project_root, 'sectionctl')}. "
            "Make sure to compile sectionctl.swift first."
        )

    cmd_parts = [sectionctl_path, args.operation]

    if args.operation == "create":
        if not args.list_id or not args.display_name:
            raise ValueError("Both --list-id and --display-name are required for create operation.")
        cmd_parts.extend([args.list_id, args.display_name])
    elif args.operation == "list":
        if args.list_id:
            cmd_parts.append(args.list_id)
    elif args.operation == "update":
        if not args.section_id or not args.display_name:
            raise ValueError("Both --section-id and --display-name are required for update operation.")
        cmd_parts.extend([args.section_id, args.display_name])
    elif args.operation == "delete":
        if not args.section_id:
            raise ValueError("--section-id is required for delete operation.")
        cmd_parts.append(args.section_id)
    elif args.operation == "lists":
        # This lists available reminder lists
        pass
    else:
        raise ValueError(f"Unsupported section operation: {args.operation}")

    try:
        result = subprocess.run(cmd_parts, capture_output=True, text=True, check=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
    except subprocess.CalledProcessError as e:
        print(f"Error running sectionctl: {e}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        raise
    except FileNotFoundError as e:
        print(f"Error: {e}. Make sure 'sectionctl' is compiled and accessible.")
        raise


def section_parser(subparsers):
    """Register the section subparser."""
    sp = subparsers.add_parser("section", help="Manage sections in reminder lists")
    sp.add_argument(
        "operation",
        choices=["create", "list", "update", "delete", "lists"],
        help="Section operation to perform"
    )
    sp.add_argument(
        "--list-id",
        dest="list_id",
        help="List name or GUID (required for create and list operations)"
    )
    sp.add_argument(
        "--section-id",
        dest="section_id",
        help="GUID of section (required for update and delete)"
    )
    sp.add_argument(
        "--display-name",
        dest="display_name",
        help="Display name for section (required for create and update)"
    )
    sp.set_defaults(func=run_section_cmd)
