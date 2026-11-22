#!/usr/bin/env python3
"""agent-net: a NetworkManager-aware connection-state check for agent tooling
(nx's metered-data budget in Task 2, agent-devshell later).

Usage:
    agent-net                   one line: "<state> (<connection>, <device>)"
    agent-net --json            {"state", "connection", "device", "source"}
    agent-net set metered|unmetered|auto
    agent-net hook session-start      Claude Code SessionStart hook
    agent-net hook prompt             Claude Code UserPromptSubmit hook

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


def _run(args, timeout: float = 1.5):
    """Run an external tool. Returns None if it's missing or fails; lets
    subprocess.TimeoutExpired propagate (a hung tool is a distinct failure
    mode from a missing one — callers that care, like the hook path, need
    to tell them apart rather than silently guessing a status)."""
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except OSError:
        return None


def _default_route(timeout: float = 1.5):
    """The device of the default route with the lowest metric, or None."""
    proc = _run(["ip", "-j", "route", "show", "default"], timeout=timeout)
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


def _nmcli_metered(dev: str, timeout: float = 1.5):
    """(is_metered, connection_name) from NetworkManager, or None if unavailable."""
    proc = _run(
        ["nmcli", "-t", "-g", "GENERAL.METERED,GENERAL.CONNECTION", "device", "show", dev],
        timeout=timeout,
    )
    if proc is None or proc.returncode != 0:
        return None
    lines = proc.stdout.splitlines()
    metered_field = lines[0] if lines else ""
    connection = lines[1] if len(lines) > 1 and lines[1] else None
    metered = metered_field.strip().startswith("yes")
    return metered, connection


def status(timeout: float = 1.5) -> dict:
    """The {"state", "connection", "device", "source"} shape used by --json.

    `timeout` bounds each of the (up to two) external calls (`ip`, `nmcli`).
    The CLI uses the default 1.5s; the Claude hooks pass a much shorter
    budget and let subprocess.TimeoutExpired propagate out of here on a
    hang, rather than returning a guessed status.
    """
    dev = _default_route(timeout=timeout)
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

    nm = _nmcli_metered(dev, timeout=timeout)
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


def _runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(base) / "agent-net"


def _sanitize_session_id(session_id):
    if not isinstance(session_id, str):
        return None
    cleaned = "".join(c for c in session_id if c.isalnum() or c in "_.-")
    return cleaned or None


def _read_session_state(session_id: str):
    try:
        return (_runtime_dir() / session_id).read_text().strip() or None
    except OSError:
        return None


def _write_session_state(session_id: str, state: str) -> None:
    d = _runtime_dir()
    d.mkdir(parents=True, exist_ok=True)
    (d / session_id).write_text(state + "\n")


def _emit_hook_output(event: str, text: str) -> None:
    print(
        json.dumps(
            {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}
        )
    )


def _hook_session_id_from_stdin():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    return _sanitize_session_id(data.get("session_id"))


# Claude's UserPromptSubmit budget is well under a second; each of the (up
# to two) external calls status() makes gets this, so the hook's worst case
# is ~2x this plus interpreter startup, not the CLI's 1.5s-per-call budget.
HOOK_TIMEOUT = 0.25


def _cmd_hook(kind: str) -> int:
    # Claude hooks must never fail closed: any error here (including a
    # hung `ip`/`nmcli` blowing the HOOK_TIMEOUT budget, raised by status()
    # as subprocess.TimeoutExpired) is swallowed and the hook exits 0 with
    # no output — and, importantly, without storing a state it never
    # actually determined, which would cause a bogus "Network changed" on
    # the next prompt once the real state is read.
    try:
        session_id = _hook_session_id_from_stdin()
        d = status(timeout=HOOK_TIMEOUT)
        state = d["state"]

        if kind == "session-start":
            if session_id:
                _write_session_state(session_id, state)
            line = _format_line(d)
            text = f'Network: {line}. See "Network" in your global instructions.'
            _emit_hook_output("SessionStart", text)
        else:  # "prompt"
            if not session_id:
                return 0
            prev = _read_session_state(session_id)
            _write_session_state(session_id, state)
            if prev is not None and prev != state:
                line = _format_line(d)
                _emit_hook_output(
                    "UserPromptSubmit", f"Network changed: now {line}."
                )
    except BaseException:
        pass
    return 0


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

    if argv[:1] == ["hook"]:
        if len(argv) != 2 or argv[1] not in ("session-start", "prompt"):
            print("usage: agent-net hook session-start|prompt", file=sys.stderr)
            return 2
        return _cmd_hook(argv[1])

    try:
        d = status()
    except subprocess.TimeoutExpired:
        # A hung `ip`/`nmcli` at the CLI's own 1.5s-per-call budget: same
        # "nothing we can say" bucket as no connectivity at all, rather
        # than a crash.
        d = {"state": "offline", "connection": None, "device": None, "source": "none"}
    if "--json" in argv:
        print(json.dumps(d))
    else:
        print(_format_line(d))
    return 0


if __name__ == "__main__":
    sys.exit(main())
