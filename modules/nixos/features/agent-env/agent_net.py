#!/usr/bin/env python3
"""agent-net: a NetworkManager-aware connection-state check for agent tooling
(nx's metered-data budget in Task 2, agent-devshell later).

Usage:
    agent-net                   one line: "<state> (<connection>, <device>)"
    agent-net --json            {"state", "connection", "device", "source"}
    agent-net set metered|unmetered|auto

State is one of "metered", "unmetered", "offline". Source is "nm" (read from
NetworkManager), "override" (forced via `set`), or "none" (no NetworkManager
available, guessed unmetered).

Override file: ${XDG_STATE_HOME:-~/.local/state}/agent-net/override. It wins
over NetworkManager, but only while there is a default route — with no route
at all the state still reports "offline" (there's nothing to call metered).
"""
import json
import os
import subprocess
import sys
from pathlib import Path

VALID_OVERRIDES = {"metered", "unmetered"}


def _state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "agent-net"


def _override_file() -> Path:
    return _state_dir() / "override"


def _read_override():
    try:
        value = _override_file().read_text().strip()
    except OSError:
        return None
    return value if value in VALID_OVERRIDES else None


def _run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=1.5)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _default_route():
    """The device of the default route with the lowest metric, or None."""
    proc = _run(["ip", "-j", "route", "show", "default"])
    if proc is None or proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        routes = json.loads(proc.stdout)
    except ValueError:
        return None
    if not routes:
        return None
    best = min(routes, key=lambda r: r.get("metric", 0))
    return best.get("dev")


def _nmcli_metered(dev: str):
    """(is_metered, connection_name) from NetworkManager, or None if unavailable."""
    proc = _run(
        ["nmcli", "-t", "-g", "GENERAL.METERED,GENERAL.CONNECTION", "device", "show", dev]
    )
    if proc is None or proc.returncode != 0:
        return None
    lines = proc.stdout.splitlines()
    metered_field = lines[0] if lines else ""
    connection = lines[1] if len(lines) > 1 and lines[1] else None
    metered = metered_field.strip().startswith("yes")
    return metered, connection


def status() -> dict:
    """The {"state", "connection", "device", "source"} shape used by --json."""
    dev = _default_route()
    override = _read_override()

    if dev is None:
        # No connectivity at all: the override still "applies" (it's what
        # caused `source` below) but can't make an offline box metered.
        return {
            "state": "offline",
            "connection": None,
            "device": None,
            "source": "override" if override else "none",
        }

    nm = _nmcli_metered(dev)
    connection = nm[1] if nm else None

    if override is not None:
        return {
            "state": override,
            "connection": connection,
            "device": dev,
            "source": "override",
        }

    if nm is None:
        return {
            "state": "unmetered",
            "connection": None,
            "device": dev,
            "source": "none",
        }

    metered, connection = nm
    return {
        "state": "metered" if metered else "unmetered",
        "connection": connection,
        "device": dev,
        "source": "nm",
    }


def _format_line(d: dict) -> str:
    extras = [v for v in (d.get("connection"), d.get("device")) if v]
    if extras:
        return f"{d['state']} ({', '.join(extras)})"
    return d["state"]


def _cmd_set(value: str) -> int:
    if value not in VALID_OVERRIDES | {"auto"}:
        print(
            f"agent-net: invalid value {value!r} (expected metered|unmetered|auto)",
            file=sys.stderr,
        )
        return 2
    override = _override_file()
    if value == "auto":
        try:
            override.unlink()
        except FileNotFoundError:
            pass
        return 0
    override.parent.mkdir(parents=True, exist_ok=True)
    override.write_text(value + "\n")
    return 0


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv

    if argv[:1] == ["set"]:
        if len(argv) != 2:
            print("usage: agent-net set metered|unmetered|auto", file=sys.stderr)
            return 2
        return _cmd_set(argv[1])

    d = status()
    if "--json" in argv:
        print(json.dumps(d))
    else:
        print(_format_line(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
