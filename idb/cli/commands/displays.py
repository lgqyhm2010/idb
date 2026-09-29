#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import json
from argparse import ArgumentParser, Namespace
from dataclasses import asdict

from idb.cli import ClientCommand
from idb.common.types import ACTIVE_DISPLAY, Client


def add_display_argument(parser: ArgumentParser) -> None:
    parser.add_argument(
        "--display",
        help="Route the touch to the active integrated display's touchscreen, "
        f"named by its unique id from `idb list-displays` or as '{ACTIVE_DISPLAY}'. "
        "Without it the touch goes to the main display. Naming a display that is "
        "unknown, is not the active integrated display or has no touchscreen "
        "fails the command rather than falling back to the main display.",
    )


def display_kwargs(args: Namespace) -> dict[str, str]:
    """Only a chosen display is passed on, so a command without --display calls
    the client exactly as it did before the option existed."""
    return {} if args.display is None else {"display": args.display}


class ListDisplaysCommand(ClientCommand):
    @property
    def description(self) -> str:
        return "List the target's displays and whether touches can be routed to them"

    @property
    def name(self) -> str:
        return "list-displays"

    def add_parser_arguments(self, parser: ArgumentParser) -> None:
        super().add_parser_arguments(parser)

    async def run_with_client(self, args: Namespace, client: Client) -> None:
        displays = await client.list_displays()
        if args.json:
            print(json.dumps([asdict(display) for display in displays]))
            return
        for display in displays:
            flags = [
                name
                for name, value in (
                    ("active", display.active),
                    ("primary", display.primary),
                    ("touchscreen", display.touchscreen),
                )
                if value
            ]
            print(
                f"{display.unique_id} | {display.name} | "
                f"{display.width:g}x{display.height:g}@{display.scale:g}x | "
                f"{display.rotation} | {' '.join(flags) or '-'}"
            )
