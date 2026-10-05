# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""Opt-in isolation evidence for disposable GitHub-hosted macOS runners."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from uuid import UUID

Run = Callable[[Sequence[str]], str]
# comm is the executable name, not argv or the process environment.
PROCESS_ARGV = ("ps", "-A", "-o", "pid,ppid,pcpu,pmem,rss,state,comm")


class IsolationError(RuntimeError):
    pass


def require_hosted_ci(device_set: Path, environment: Mapping[str, str]) -> None:
    if not (
        environment.get("GITHUB_ACTIONS") == "true"
        and environment.get("RUNNER_ENVIRONMENT") == "github-hosted"
        and environment.get("RUNNER_OS") == "macOS"
    ):
        raise IsolationError("Isolation requires a GitHub-hosted macOS CI runner")
    temporary = environment.get("RUNNER_TEMP")
    if not temporary or not device_set.resolve().is_relative_to(
        Path(temporary).resolve()
    ):
        raise IsolationError("Dedicated device set must be inside RUNNER_TEMP")
    if device_set.resolve() == Path(temporary).resolve():
        raise IsolationError("RUNNER_TEMP itself is not a dedicated device set")
    default = Path.home() / "Library/Developer/CoreSimulator/Devices"
    if device_set.resolve() == default.resolve():
        raise IsolationError("Isolation requires a non-default dedicated device set")


def run_command(argv: Sequence[str]) -> str:
    return subprocess.run(
        list(argv), check=True, capture_output=True, text=True, timeout=30
    ).stdout


def inventory_argv(device_set: Path | None) -> list[str]:
    scope = [] if device_set is None else ["--set", str(device_set)]
    return ["xcrun", "simctl", *scope, "list", "--json", "devices"]


def devices(output: str) -> dict[str, str]:
    """Reject malformed inventories rather than mistaking them for an empty set."""
    document = json.loads(output)
    groups = document["devices"]
    if not isinstance(groups, dict):
        raise IsolationError("Malformed simulator inventory")
    result = {}
    for rows in groups.values():
        if not isinstance(rows, list):
            raise IsolationError("Malformed simulator inventory rows")
        for row in rows:
            udid, state = row["udid"], row["state"]
            udid = str(UUID(udid)).upper()
            if not isinstance(state, str) or udid in result:
                raise IsolationError("Malformed or duplicate simulator inventory entry")
            result[udid] = state
    return result


def snapshot(
    directory: Path, phase: str, device_set: Path, run: Run = run_command
) -> dict[str, str]:
    """Keep each failure visible and attempt all three independent diagnostics."""
    directory.mkdir(parents=True, exist_ok=True)
    outputs = {}
    status = {}
    for name, argv in (
        ("default-devices", inventory_argv(None)),
        ("dedicated-devices", inventory_argv(device_set)),
        ("processes", PROCESS_ARGV),
    ):
        try:
            output = run(argv)
            (directory / f"{phase}-{name}.txt").write_text(output)
            outputs[name] = output
            status[name] = "captured"
        except (OSError, subprocess.SubprocessError) as error:
            # Avoid including stdout/stderr or argv from failed commands.
            status[name] = f"capture failed: {type(error).__name__}"
    (directory / f"{phase}-status.json").write_text(json.dumps(status, indent=2) + "\n")
    return outputs


def safe_snapshot(
    directory: Path, phase: str, device_set: Path, run: Run = run_command
) -> dict[str, str]:
    """A diagnostic write failure must not mask a shutdown or boot failure."""
    try:
        return snapshot(directory, phase, device_set, run)
    except (OSError, subprocess.SubprocessError) as error:
        print(
            f"{phase} snapshot capture failed: {type(error).__name__}", file=sys.stderr
        )
        return {}


def save_target(directory: Path, device_set: Path, target: str) -> None:
    target = str(UUID(target)).upper()
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "target.json").write_text(
        json.dumps({"device_set": str(device_set.resolve()), "udid": target}) + "\n"
    )


def recover_target(directory: Path, device_set: Path) -> str | None:
    """Only recover a valid UDID for the exact caller-selected dedicated set."""
    try:
        value = json.loads((directory / "target.json").read_text())
        target = value["udid"]
        target = str(UUID(target)).upper()
        if value["device_set"] != str(device_set.resolve()):
            raise IsolationError("Saved target belongs to another device set")
        return target
    except (
        OSError,
        ValueError,
        TypeError,
        KeyError,
        AttributeError,
        IsolationError,
    ) as error:
        print(f"Target metadata unavailable: {type(error).__name__}", file=sys.stderr)
        return None


def isolate(
    device_set: Path,
    target: str,
    directory: Path,
    *,
    run: Run = run_command,
    environment: Mapping[str, str] | None = None,
) -> None:
    require_hosted_ci(device_set, os.environ if environment is None else environment)
    target = str(UUID(target)).upper()
    before = snapshot(directory, "before-isolation", device_set, run)
    report: dict[str, object] = {
        "target": target,
        "selected": [],
        "verified_shutdown": [],
        "result": "failed",
    }
    try:
        defaults = devices(before["default-devices"])
        dedicated = devices(before["dedicated-devices"])
        if target not in dedicated:
            raise IsolationError("Target missing from dedicated device set")
        if any(
            state == "Booted" and udid != target for udid, state in dedicated.items()
        ):
            raise IsolationError(
                "Unexpected booted dedicated device; refusing to change it"
            )
        extra = sorted(
            udid
            for udid, state in defaults.items()
            if state == "Booted" and udid != target
        )
        report["selected"] = extra
        # Capture even if a command partly changes state and then times out.
        try:
            for udid in extra:
                run(["xcrun", "simctl", "shutdown", udid])
        finally:
            after = safe_snapshot(directory, "after-isolation", device_set, run)
        remaining = devices(after["default-devices"])
        preserved = devices(after["dedicated-devices"])
        if any(
            state == "Booted" and udid != target for udid, state in preserved.items()
        ):
            raise IsolationError(
                "Unexpected dedicated device became booted during isolation"
            )
        if preserved.get(target) != dedicated[target]:
            raise IsolationError("Dedicated target changed state during isolation")
        if any(remaining.get(udid) != "Shutdown" for udid in extra):
            raise IsolationError("Default-device shutdown was not verified")
        if any(
            state == "Booted" and udid != target for udid, state in remaining.items()
        ):
            raise IsolationError("Unexpected default device remains booted")
        report["verified_shutdown"] = extra
        report["result"] = (
            "isolated" if extra else "no-op: no extra booted default devices"
        )
    except (
        KeyError,
        TypeError,
        ValueError,
        OSError,
        subprocess.SubprocessError,
        IsolationError,
    ) as error:
        report["error"] = f"Isolation failed: {type(error).__name__}"
        raise IsolationError(str(report["error"])) from error
    finally:
        try:
            (directory / "isolation-result.json").write_text(
                json.dumps(report, indent=2) + "\n"
            )
        except OSError as error:
            print(
                f"Isolation result capture failed: {type(error).__name__}",
                file=sys.stderr,
            )
            if report["result"] != "failed":
                raise
    print(report["result"], file=sys.stderr)


def crash_report_metadata(
    directory: Path,
    *,
    home: Path,
    system_reports: Path = Path("/Library/Logs/DiagnosticReports"),
    device_set: Path | None = None,
    target: str | None = None,
) -> None:
    """Inventory report names, sizes and mtimes without opening report contents."""
    roots = {
        "host-user": home / "Library/Logs/DiagnosticReports",
        "host-system": system_reports,
    }
    if device_set is not None and target is not None:
        target = str(UUID(target)).upper()
        roots["simulator"] = device_set / target / "data/Library/Logs/CrashReporter"
    result = {}
    for name, root in roots.items():
        files = []
        status = "captured"
        try:
            for path in sorted(root.iterdir()):
                if path.suffix not in (".ips", ".crash"):
                    continue
                try:
                    metadata = path.lstat()
                    if not stat.S_ISREG(metadata.st_mode):
                        continue
                    files.append(
                        {
                            "name": path.name,
                            "size": metadata.st_size,
                            "mtime_ns": metadata.st_mtime_ns,
                        }
                    )
                except OSError as error:
                    files.append({"name": path.name, "error": type(error).__name__})
        except OSError as error:
            status = f"capture failed: {type(error).__name__}"
        result[name] = {"status": status, "files": files}
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "crash-report-metadata.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
