#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.


import asyncio
import json
import logging
import os
import tempfile
import time
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import List, Optional

from idb.common.constants import IDB_STATE_FILE_PATH
from idb.common.format import json_data_companions, json_to_companion_info
from idb.common.types import (
    CompanionInfo,
    ConnectionDestination,
    DomainSocketAddress,
    IdbException,
    TCPAddress,
)


@asynccontextmanager
async def _open_lockfile(filename: str) -> AsyncGenerator[None, None]:
    timeout = 3
    retry_time = 0.05
    deadline = time.monotonic() + timeout
    lock_path = filename + ".lock"
    Path(filename).parent.mkdir(parents=True, exist_ok=True)
    while True:
        try:
            lock = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o644)
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                raise IdbException(f"Failed to open the lockfile {lock_path}")
            await asyncio.sleep(retry_time)
    # Only the successful owner may release the lock. Exceptions from the body
    # (including FileExistsError) must not be mistaken for acquisition failure.
    try:
        yield None
    finally:
        os.close(lock)
        os.unlink(lock_path)


class CompanionSet:
    def __init__(
        self, logger: logging.Logger, state_file_path: str = IDB_STATE_FILE_PATH
    ) -> None:
        self.state_file_path = state_file_path
        self.logger = logger

    @asynccontextmanager
    async def _use_stored_companions(self) -> AsyncGenerator[list[CompanionInfo], None]:
        async with _open_lockfile(filename=self.state_file_path):
            path = Path(self.state_file_path)
            try:
                contents = path.read_text()
            except FileNotFoundError:
                contents = ""
            fresh_state = not contents
            if fresh_state:
                companion_info_in = []
            else:
                try:
                    companion_info_in = json_to_companion_info(json.loads(contents))
                except json.JSONDecodeError as error:
                    # Leave the original bytes intact for diagnosis/recovery.
                    raise IdbException(
                        f"Invalid companion state file {self.state_file_path}; "
                        "preserving it instead of overwriting the registry"
                    ) from error
            companion_info_in = sorted(
                companion_info_in, key=lambda companion: companion.udid
            )
            companion_info_out = list(companion_info_in)
            yield companion_info_out
            companion_info_out = sorted(
                companion_info_out, key=lambda companion: companion.udid
            )
            if fresh_state:
                self.logger.info(
                    f"Created a fresh companion info of {companion_info_out}, writing to file"
                )
            elif companion_info_in != companion_info_out:
                self.logger.info(
                    f"Companion info changed from {companion_info_in} to {companion_info_out}, writing to file"
                )
            else:
                return
            temporary_path = None
            try:
                with tempfile.NamedTemporaryFile(
                    mode="w", dir=path.parent, prefix=path.name + ".", delete=False
                ) as f:
                    temporary_path = f.name
                    json.dump(json_data_companions(companion_info_out), f)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(temporary_path, self.state_file_path)
            finally:
                if temporary_path is not None and os.path.exists(temporary_path):
                    os.unlink(temporary_path)

    async def get_companions(self) -> list[CompanionInfo]:
        async with self._use_stored_companions() as companions:
            return companions

    async def add_companion(self, companion: CompanionInfo) -> CompanionInfo | None:
        async with self._use_stored_companions() as companions:
            udid = companion.udid
            current = {existing.udid: existing for existing in companions}
            existing = current.get(udid)
            if existing is not None:
                existing = current[udid]
                current[udid] = companion
                self.logger.info(f"Replacing {existing} with {companion}")
                companions.clear()
                companions.extend(current.values())
                return existing
            self.logger.info(f"Adding companion {companion}")
            companions.append(companion)
            return None

    async def clear(self) -> list[CompanionInfo]:
        async with self._use_stored_companions() as companions:
            cleared = list(companions)
            companions.clear()
            return cleared

    async def remove_companion(
        self, destination: ConnectionDestination
    ) -> list[CompanionInfo]:
        async with self._use_stored_companions() as companions:
            if isinstance(destination, str):
                to_remove = [
                    companion
                    for companion in companions
                    if companion.udid == destination
                ]
            elif isinstance(destination, TCPAddress):
                to_remove = [
                    companion
                    for companion in companions
                    if (
                        isinstance(companion.address, TCPAddress)
                        and companion.address.host == destination.host
                        and companion.address.port == destination.port
                    )
                ]
            elif isinstance(destination, DomainSocketAddress):
                to_remove = [
                    companion
                    for companion in companions
                    if (
                        isinstance(companion.address, DomainSocketAddress)
                        and companion.address.path == destination.path
                    )
                ]
            else:
                to_remove = []
            for companion in to_remove:
                companions.remove(companion)
            return to_remove
