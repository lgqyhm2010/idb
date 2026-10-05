# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Test-only, fail-closed observation of SpringBoard's notification banner.

These private log messages are evidence of presentation, unlike delivery to the
notification store. If the runtime changes them, the demo fails without tapping.
"""

from __future__ import annotations

import re
from datetime import datetime
from typing import Callable

from .harness import Deadline, HarnessError, IdbProcess

# The monitor event is routine, non-mutating evidence that the subscription is
# actually streaming before we send. Keep the stream small on loaded CI hosts.
BANNER_LOG_PREDICATE = (
    'process == "SpringBoard" AND ('
    '(subsystem == "com.apple.runningboard" AND category == "monitor") OR '
    'eventMessage CONTAINS "Adding notification request" OR '
    'eventMessage CONTAINS "UNNotificationRequest:" OR '
    'eventMessage CONTAINS "as banner")'
)
_COMPACT_EVENT = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+\S+\s+"
    r"SpringBoard\[\d+:[0-9a-fA-F]+\] (.*)$"
)
_DIGEST = r"[0-9A-F]{4}-[0-9A-F]{4}"
_UUID = r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}"
_REQUEST = re.compile(
    rf"for request ({_DIGEST}) <UNNotificationRequest: .*?; identifier: ({_UUID}),"
)
_PRESENTABLE = re.compile(
    rf"requestIdentifier: ({_UUID});.*?logDigest: ({_DIGEST})>"
)
_LOST_EVENTS = re.compile(
    r"(?i)(?:^===.*(?:dropped|lost)|(?:dropped|lost) \d+ (?:messages|events))"
)


class NotificationBanner:
    def __init__(
        self,
        log: IdbProcess,
        bundle_id: str,
        *,
        now: Callable[[], datetime] = datetime.now,
        max_age_seconds: float = 1.0,
    ) -> None:
        self.log = log
        self.now = now
        self.max_age_seconds = max_age_seconds
        self.started_at = now()
        self.sending_at: datetime | None = None
        self.streaming = False
        self.digest: str | None = None
        self.request_id: str | None = None
        self.appeared_at: datetime | None = None
        self._old_digests: set[str] = set()
        self._pending = b""
        self._read_bytes = 0
        self._adding = re.compile(
            rf"\[{re.escape(bundle_id)}\] Adding notification request ({_DIGEST}) to destinations:"
        )

    def begin_send(self) -> None:
        self.sending_at = self.now()

    def _feed(self, data: bytes) -> None:
        self._pending += data
        lines = self._pending.split(b"\n")
        self._pending = lines.pop()
        if len(self._pending) > 64 * 1024:
            raise HarnessError("Notification log has an unterminated line")
        for raw in lines:
            line = raw.decode("utf-8", errors="strict")
            if _LOST_EVENTS.search(line):
                raise HarnessError(f"Notification log lost events: {line}")
            event = _COMPACT_EVENT.match(line)
            if event is None:
                continue
            at = datetime.strptime(event[1], "%Y-%m-%d %H:%M:%S.%f")
            message = event[2]
            age = (self.now() - at).total_seconds()
            if at >= self.started_at and 0 <= age <= self.max_age_seconds:
                self.streaming = True
            adding = self._adding.search(message)
            if self.sending_at is None or at < self.sending_at:
                if adding:
                    self._old_digests.add(adding[1])
                continue
            if adding:
                digest = adding[1]
                if digest in self._old_digests:
                    continue
                if self.digest is not None and self.digest != digest:
                    raise HarnessError("More than one fresh News notification request")
                self.digest = digest
            if self.digest is None:
                continue
            request = _REQUEST.search(message)
            if request and request[1] == self.digest:
                if self.request_id is not None and self.request_id != request[2]:
                    raise HarnessError("Notification digest matched different request IDs")
                self.request_id = request[2]
            presentable = _PRESENTABLE.search(message)
            if presentable is None or presentable[2] != self.digest:
                continue
            if "disappear as banner" in message:
                raise HarnessError("The notification banner was dismissed before the tap")
            if "did appear as banner:" not in message:
                continue
            if self.request_id is None or presentable[1] != self.request_id:
                raise HarnessError("Notification appearance has no matching full request ID")
            self.appeared_at = at

    async def _read(self, deadline: Deadline) -> None:
        if deadline.passed:
            raise HarnessError("Timed out waiting for notification banner evidence")
        data = await self.log.read_some(deadline.remaining)
        if not data:
            raise HarnessError("Notification log ended before the banner was ready")
        self._read_bytes += len(data)
        self._feed(data)

    async def wait_for_stream(self, timeout: float) -> None:
        deadline = Deadline(timeout)
        while not self.streaming:
            await self._read(deadline)
        self._require_live_stream()

    def _require_live_stream(self) -> None:
        if self.log.returncode is not None:
            raise HarnessError("Notification log stopped streaming")

    async def wait_for_presentation(self, deadline: Deadline) -> None:
        while True:
            await self._read(deadline)
            # Do not accept an appearance ahead of an already-buffered dismissal,
            # including a dismissal split across chunks or a partial final line.
            if self._read_bytes < self.log.stdout_capture.total_bytes or self._pending:
                continue
            if self.appeared_at is not None:
                self.require_current_presentation()
                return

    def require_current_presentation(self) -> None:
        self._require_live_stream()
        if self.appeared_at is None:
            raise HarnessError("No matching notification banner appeared")
        age = (self.now() - self.appeared_at).total_seconds()
        if not 0 <= age <= self.max_age_seconds:
            raise HarnessError("Notification banner evidence is stale or its clock disagrees")
