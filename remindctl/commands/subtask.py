# remindctl/commands/subtask.py
"""Subtask management commands for remindctl."""

import subprocess
import os


def run_subtask_cmd(args):
    """Execute the subtaskctl binary with the given arguments."""
    # Determine the path to the compiled subtaskctl binary
    # The binary is in the project root, which is two directories up from this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(os.path.dirname(script_dir))
    subtaskctl_path = os.path.join(project_root, "subtaskctl")

    if not os.path.exists(subtaskctl_path):
        # Fallback: check if it's in the same directory as the package
        package_dir = os.path.dirname(script_dir)
        subtaskctl_path = os.path.join(package_dir, "subtaskctl")
        
    if not os.path.exists(subtaskctl_path):
        raise FileNotFoundError(
            f"subtaskctl binary not found. Expected at {os.path.join(project_root, 'subtaskctl')}. "
            "Make sure to compile subtaskctl.swift first."
        )

    cmd_parts = [subtaskctl_path, args.operation]

    if args.operation == "create":
        if not args.parent_id or not args.title:
            raise ValueError("Both --parent-id and --title are required for create operation.")
        cmd_parts.extend([args.parent_id, args.title])
    elif args.operation == "list":
        if not args.parent_id:
            raise ValueError("--parent-id is required for list operation.")
        cmd_parts.append(args.parent_id)
    elif args.operation == "update":
        if not args.subtask_id:
            raise ValueError("--subtask-id is required for update operation.")
        cmd_parts.append(args.subtask_id)
        if args.new_title:
            cmd_parts.append(args.new_title)
    elif args.operation == "delete":
        if not args.subtask_id:
            raise ValueError("--subtask-id is required for delete operation.")
        cmd_parts.append(args.subtask_id)
    else:
        raise ValueError(f"Unsupported subtask operation: {args.operation}")

    try:
        result = subprocess.run(cmd_parts, capture_output=True, text=True, check=True)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='')
    except subprocess.CalledProcessError as e:
        print(f"Error running subtaskctl: {e}")
        print(f"Stdout: {e.stdout}")
        print(f"Stderr: {e.stderr}")
        raise
    except FileNotFoundError as e:
        print(f"Error: {e}. Make sure 'subtaskctl' is compiled and accessible.")
        raise


def subtask_parser(subparsers):
    """Register the subtask subparser."""
    sp = subparsers.add_parser("subtask", help="Manage subtasks")
    sp.add_argument(
        "operation",
        choices=["create", "list", "update", "delete"],
        help="Subtask operation to perform"
    )
    sp.add_argument(
        "--parent-id",
        dest="parent_id",
        help="GUID of parent reminder (required for create and list)"
    )
    sp.add_argument(
        "--subtask-id",
        dest="subtask_id",
        help="GUID of subtask (required for update and delete)"
    )
    sp.add_argument(
        "--title",
        dest="title",
        help="Title for new subtask (required for create)"
    )
    sp.add_argument(
        "--new-title",
        dest="new_title",
        help="New title for update operation"
    )
    sp.set_defaults(func=run_subtask_cmd)
