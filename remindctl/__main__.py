#!/usr/bin/env python3
"""remindctl - Python CLI wrapper for reminder management."""

import argparse
import sys

from remindctl.commands.subtask import subtask_parser


def main():
    """Main entry point for the remindctl CLI."""
    parser = argparse.ArgumentParser(
        prog="remindctl",
        description="Reminder management CLI"
    )
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s 0.1.0"
    )
    
    subparsers = parser.add_subparsers(
        title="commands",
        description="Available commands",
        dest="command"
    )
    
    # Register command parsers
    subtask_parser(subparsers)
    
    # Parse arguments
    args = parser.parse_args()
    
    if args.command is None:
        parser.print_help()
        sys.exit(0)
    
    # Execute the command handler
    if hasattr(args, 'func'):
        try:
            args.func(args)
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
