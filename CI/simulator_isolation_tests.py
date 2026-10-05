# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Pure contract tests for opt-in hosted-runner isolation and safe diagnostics."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .simulator_isolation import (
    IsolationError,
    PROCESS_ARGV,
    devices,
    crash_report_metadata,
    inventory_argv,
    isolate,
    require_hosted_ci,
    snapshot,
    save_target,
    recover_target,
)

TARGET = "11111111-1111-4111-8111-111111111111"
EXTRA = "22222222-2222-4222-8222-222222222222"
OFF = "33333333-3333-4333-8333-333333333333"


def listing(rows):
    return json.dumps(
        {
            "devices": {
                "runtime": [
                    {"udid": key, "state": value} for key, value in rows.items()
                ]
            }
        }
    )


class IsolationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.device_set = self.root / "dedicated.noindex"
        self.output = self.root / "diagnostics"
        self.environment = {
            "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted",
            "RUNNER_OS": "macOS",
            "RUNNER_TEMP": str(self.root),
        }
        self.commands = []
        self.defaults = {EXTRA: "Booted", OFF: "Shutdown"}
        self.dedicated = {TARGET: "Shutdown"}

    def run_command(self, argv):
        self.commands.append(list(argv))
        if tuple(argv) == PROCESS_ARGV:
            return "PID PPID %CPU %MEM RSS STAT COMM\n"
        if "shutdown" in argv:
            self.defaults[argv[-1]] = "Shutdown"
            return ""
        return listing(self.dedicated if "--set" in argv else self.defaults)

    def isolate(self, run=None):
        isolate(
            self.device_set,
            TARGET,
            self.output,
            run=run or self.run_command,
            environment=self.environment,
        )

    def report(self):
        return json.loads((self.output / "isolation-result.json").read_text())

    def test_shutdown_only_exact_booted_default_device_and_verify(self):
        self.isolate()
        self.assertEqual(
            self.commands,
            [
                inventory_argv(None),
                inventory_argv(self.device_set),
                list(PROCESS_ARGV),
                ["xcrun", "simctl", "shutdown", EXTRA],
                inventory_argv(None),
                inventory_argv(self.device_set),
                list(PROCESS_ARGV),
            ],
        )
        self.assertEqual(self.report()["verified_shutdown"], [EXTRA])
        self.assertEqual(self.report()["result"], "isolated")

    def test_preserve_target_even_if_default_inventory_also_names_it(self):
        self.defaults[TARGET] = "Booted"
        self.dedicated[TARGET] = "Booted"
        self.isolate()
        self.assertNotIn(["xcrun", "simctl", "shutdown", TARGET], self.commands)
        self.assertEqual(self.dedicated[TARGET], "Booted")

    def test_target_protection_compares_canonical_uuid_identity(self):
        target = "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF"
        self.defaults = {target.lower(): "Booted", EXTRA: "Booted"}
        self.dedicated = {target: "Booted"}
        isolate(
            self.device_set,
            target.lower(),
            self.output,
            run=self.run_command,
            environment=self.environment,
        )
        self.assertEqual(
            [command for command in self.commands if "shutdown" in command],
            [["xcrun", "simctl", "shutdown", EXTRA]],
        )
        self.assertEqual(self.report()["target"], target)

    def test_zero_extra_devices_is_explicit_no_op(self):
        self.defaults = {OFF: "Shutdown"}
        self.isolate()
        self.assertFalse(any("shutdown" in command for command in self.commands))
        self.assertEqual(
            self.report()["result"], "no-op: no extra booted default devices"
        )

    def test_guards_prevent_any_command(self):
        for key in list(self.environment):
            with self.subTest(key=key):
                original = self.environment.pop(key)
                try:
                    with self.assertRaises(IsolationError):
                        self.isolate()
                finally:
                    self.environment[key] = original
        self.assertEqual(self.commands, [])

    def test_reject_set_outside_runner_temp_and_temp_itself(self):
        for path in (self.root, self.root.parent / "elsewhere"):
            with self.subTest(path=path), self.assertRaises(IsolationError):
                require_hosted_ci(path, self.environment)

    def test_extra_dedicated_device_is_not_shutdown(self):
        self.dedicated[EXTRA] = "Booted"
        with self.assertRaises(IsolationError):
            self.isolate()
        self.assertFalse(any("shutdown" in command for command in self.commands))

    def test_missing_target_fails_before_mutation(self):
        self.dedicated = {}
        with self.assertRaises(IsolationError):
            self.isolate()
        self.assertFalse(any("shutdown" in command for command in self.commands))

    def test_newly_booted_dedicated_device_fails_post_isolation_verification(self):
        def racing(argv):
            value = self.run_command(argv)
            if "shutdown" in argv:
                self.dedicated[OFF] = "Booted"
            return value

        with self.assertRaises(IsolationError):
            self.isolate(racing)
        self.assertEqual(self.report()["result"], "failed")
        self.assertNotIn(["xcrun", "simctl", "shutdown", OFF], self.commands)

    def test_partial_shutdown_timeout_still_captures_after_state(self):
        failure = subprocess.TimeoutExpired("shutdown", 30)

        def partial(argv):
            value = self.run_command(argv)
            if "shutdown" in argv:
                raise failure
            return value

        with self.assertRaises(IsolationError) as raised:
            self.isolate(partial)
        self.assertIs(raised.exception.__cause__, failure)
        after = devices(
            (self.output / "after-isolation-default-devices.txt").read_text()
        )
        self.assertEqual(after[EXTRA], "Shutdown")
        self.assertEqual(self.report()["result"], "failed")

    def test_after_snapshot_write_failure_does_not_mask_shutdown_failure(self):
        from . import simulator_isolation

        original = simulator_isolation.snapshot
        failure = subprocess.TimeoutExpired("shutdown", 30)

        def partial(argv):
            if "shutdown" in argv:
                raise failure
            return self.run_command(argv)

        def failed_snapshot(directory, phase, device_set, run):
            if phase == "after-isolation":
                raise OSError("disk unavailable")
            return original(directory, phase, device_set, run)

        with mock.patch.object(
            simulator_isolation, "snapshot", side_effect=failed_snapshot
        ):
            with self.assertRaises(IsolationError) as raised:
                self.isolate(partial)
        self.assertIs(raised.exception.__cause__, failure)

    def test_saved_target_recovery_is_scoped_and_validates_udid(self):
        save_target(self.output, self.device_set, TARGET)
        self.assertEqual(recover_target(self.output, self.device_set), TARGET)
        self.assertIsNone(recover_target(self.output, self.root / "other"))
        (self.output / "target.json").write_text(
            json.dumps(
                {"device_set": str(self.device_set.resolve()), "udid": "../../other"}
            )
        )
        self.assertIsNone(recover_target(self.output, self.device_set))

    def test_unsuccessful_shutdown_is_not_reported_as_isolation(self):
        def no_shutdown(argv):
            if "shutdown" in argv:
                return ""
            return self.run_command(argv)

        with self.assertRaises(IsolationError):
            self.isolate(no_shutdown)
        self.assertEqual(self.report()["result"], "failed")

    def test_inventory_failure_prevents_mutation_but_keeps_other_diagnostics(self):
        def failed(argv):
            if list(argv) == inventory_argv(None):
                raise subprocess.TimeoutExpired(argv, 30)
            return self.run_command(argv)

        with self.assertRaises(IsolationError):
            self.isolate(failed)
        self.assertTrue((self.output / "before-isolation-processes.txt").is_file())
        self.assertFalse(any("shutdown" in command for command in self.commands))
        status = json.loads((self.output / "before-isolation-status.json").read_text())
        self.assertIn("TimeoutExpired", status["default-devices"])

    def test_process_capture_failure_is_visible_without_masking_inventory(self):
        def failed(argv):
            if tuple(argv) == PROCESS_ARGV:
                raise subprocess.CalledProcessError(1, argv, output="sensitive output")
            return self.run_command(argv)

        self.isolate(failed)
        status = (self.output / "before-isolation-status.json").read_text()
        self.assertIn("CalledProcessError", status)
        self.assertNotIn("sensitive output", status)
        self.assertEqual(self.report()["result"], "isolated")

    def test_invalid_inventory_is_not_empty(self):
        for value in ("{}", '{"devices": []}', listing({"all": "Booted"})):
            with self.subTest(value=value), self.assertRaises(
                (KeyError, ValueError, IsolationError)
            ):
                devices(value)

    def test_crash_metadata_never_reads_contents_and_tolerates_missing_roots(self):
        home = self.root / "home"
        reports = home / "Library/Logs/DiagnosticReports"
        reports.mkdir(parents=True)
        report = reports / "Fixture.ips"
        report.write_text("private report contents")
        (reports / "unrelated.txt").write_text("not a report")
        (reports / "Alias.ips").symlink_to(report)
        crash_report_metadata(
            self.output,
            home=home,
            system_reports=self.root / "missing",
            device_set=self.device_set,
            target=TARGET,
        )
        result = json.loads((self.output / "crash-report-metadata.json").read_text())
        self.assertEqual(
            result["host-user"]["files"],
            [
                {
                    "name": "Fixture.ips",
                    "size": report.stat().st_size,
                    "mtime_ns": report.stat().st_mtime_ns,
                }
            ],
        )
        self.assertIn("FileNotFoundError", result["host-system"]["status"])
        self.assertIn("FileNotFoundError", result["simulator"]["status"])
        self.assertNotIn("private report contents", json.dumps(result))

    def test_snapshot_uses_only_executable_and_resource_fields(self):
        snapshot(self.output, "end", self.device_set, self.run_command)
        self.assertEqual(
            PROCESS_ARGV, ("ps", "-A", "-o", "pid,ppid,pcpu,pmem,rss,state,comm")
        )
        self.assertEqual(len(self.commands), 3)


if __name__ == "__main__":
    unittest.main()
