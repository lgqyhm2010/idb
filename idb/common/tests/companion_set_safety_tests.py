#!/usr/bin/env python3
import asyncio
import json
import tempfile
from pathlib import Path
from unittest import IsolatedAsyncioTestCase, mock

from idb.common.companion_set import CompanionSet, _open_lockfile
from idb.common.types import CompanionInfo, IdbException, TCPAddress


class CompanionSetSafetyTests(IsolatedAsyncioTestCase):
    async def test_timeout_does_not_release_owner_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "state")
            async with _open_lockfile(path):
                with mock.patch("idb.common.companion_set.time.monotonic", side_effect=[0, 4]):
                    with self.assertRaises(IdbException):
                        async with _open_lockfile(path):
                            self.fail("waiter entered")
                self.assertTrue(Path(path + ".lock").exists())
                # A third contender still cannot enter while the first owns it.
                with mock.patch("idb.common.companion_set.time.monotonic", side_effect=[0, 4]):
                    with self.assertRaises(IdbException):
                        async with _open_lockfile(path):
                            self.fail("third contender entered")
            self.assertFalse(Path(path + ".lock").exists())

    async def test_cancellation_does_not_release_owner_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "state")
            async def wait_for_lock():
                async with _open_lockfile(path):
                    self.fail("cancelled waiter entered")
            async with _open_lockfile(path):
                task = asyncio.create_task(wait_for_lock())
                await asyncio.sleep(0)
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
                self.assertTrue(Path(path + ".lock").exists())

    async def test_body_file_exists_error_is_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "nested" / "state")
            with self.assertRaisesRegex(FileExistsError, "body error"):
                async with _open_lockfile(path):
                    raise FileExistsError("body error")
            self.assertFalse(Path(path + ".lock").exists())
            async with _open_lockfile(path):
                self.assertTrue(Path(path + ".lock").exists())

    async def test_invalid_state_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state"
            path.write_text('[{"udid":')
            manager = CompanionSet(mock.Mock(), str(path))
            with self.assertRaisesRegex(IdbException, "preserving"):
                await manager.clear()
            self.assertEqual(path.read_text(), '[{"udid":')
            self.assertFalse(Path(str(path) + ".lock").exists())

    async def test_failed_replace_leaves_old_json_and_cleans_temporary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state"
            manager = CompanionSet(mock.Mock(), str(path))
            first = CompanionInfo(udid="a", address=TCPAddress("localhost", 1), is_local=True, pid=None)
            await manager.add_companion(first)
            before = path.read_bytes()
            with mock.patch("idb.common.companion_set.os.replace", side_effect=OSError("interrupted")):
                with self.assertRaisesRegex(OSError, "interrupted"):
                    await manager.clear()
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(await manager.get_companions(), [first])
            self.assertEqual(list(Path(directory).iterdir()), [path])
            await manager.clear()
            self.assertEqual(json.loads(path.read_text()), [])
