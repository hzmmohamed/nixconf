"""agent-broker: run one agent command as a per-project Unix user.

One instance per connection (systemd socket activation, Accept=yes): fd 0 is
the connection. The client (agent_brokered.py, running as the orchestrator
user) sends one JSON line {argv, cwd, env, pty} together with its stdin,
stdout and stderr file descriptors (SCM_RIGHTS). The broker

  1. resolves the project from the *real* cwd (never from a client claim):
     it must lie inside exactly one registered project root or worktrees dir;
  2. checks argv[0] against that project's allowed commands and, when the
     client passes CLAUDE_CONFIG_DIR, that it is the project's one;
  3. keeps only allow-listed environment variables and sets HOME, PATH and
     the project's fixed variables itself;
  4. starts `systemd-run --pipe|--pty --wait --uid=<project user> ...` with
     the received descriptors as the unit's stdio and the sandbox properties
     from the registry;
  5. stops the unit as soon as the control connection closes (the wrapper
     was killed: T3 kills by pid and process group, which never crosses a
     UID boundary) or the unit exits, then reports the exit status.

Registry: /etc/agent-broker/projects.json (AGENT_BROKER_REGISTRY), written
by the NixOS module. Only stdlib. Logs go to stderr (the journal); stdout is
never used because fd 1 may be the connection.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import select
import socket
import subprocess
import sys
from pathlib import Path

REGISTRY_ENV = "AGENT_BROKER_REGISTRY"
DEFAULT_REGISTRY = "/etc/agent-broker/projects.json"
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
# What any provider child may inherit from the orchestrator. Everything else
# (SSH_AUTH_SOCK, GH_TOKEN, AWS_*, LD_*, …) is dropped; the project's own
# `envAllow` extends this list.
BASE_ENV_ALLOW = (
    "TERM",
    "LANG",
    "LC_ALL",
    "COLORTERM",
    "TERM_PROGRAM",
    "TZ",
    "DIRENV_CONFIG",
    "T3CODE_THREAD_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_RESUME_INTERRUPTED_TURN",
    "CLAUDE_CODE_RESUME_REASON",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "OPENCODE_SERVER_PASSWORD",
    "OPENCODE_CONFIG_CONTENT",
    "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
)
EXIT_REFUSED = 125
EXIT_BROKER_ERROR = 126


class Refused(Exception):
    """A request the policy rejects; the reason goes back to the client."""


def load_registry(path: str | None = None) -> dict:
    with open(path or os.environ.get(REGISTRY_ENV, DEFAULT_REGISTRY), encoding="utf-8") as f:
        registry = json.load(f)
    if not isinstance(registry.get("projects"), dict):
        raise Refused("registry has no projects")
    return registry


def _within(path: str, root: str) -> bool:
    root = root.rstrip("/")
    return path == root or path.startswith(root + "/")


def resolve_project(registry: dict, cwd: str) -> tuple[str, dict]:
    """The one project whose root or worktrees dir contains the real cwd."""
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        raise Refused("cwd must be an absolute path")
    real = os.path.realpath(cwd)
    if not os.path.isdir(real):
        raise Refused(f"cwd does not exist: {cwd}")
    matches = [
        (name, project)
        for name, project in registry["projects"].items()
        if any(_within(real, root) for root in (project["path"], project["worktreesDir"]))
    ]
    if not matches:
        raise Refused(f"cwd is in no registered project: {real}")
    if len(matches) > 1:
        raise Refused(f"cwd is in several projects: {', '.join(n for n, _ in matches)}")
    return matches[0]


def validate_argv(project: dict, argv) -> list[str]:
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise Refused("argv must be a non-empty list of strings")
    if any("\0" in a for a in argv):
        raise Refused("argv contains NUL")
    command = os.path.realpath(argv[0]) if argv[0].startswith("/") else None
    allowed = {os.path.realpath(c) for c in project.get("allowedCommands", [])}
    if command is None or command not in allowed:
        raise Refused(f"command not allowed for this project: {argv[0]}")
    return [command, *argv[1:]]


def filter_env(registry: dict, project: dict, env) -> dict[str, str]:
    """Allow-listed caller variables, then the project's fixed ones on top."""
    if not isinstance(env, dict):
        raise Refused("env must be an object")
    allow = set(BASE_ENV_ALLOW) | set(registry.get("envAllow", [])) | set(project.get("envAllow", []))
    kept: dict[str, str] = {}
    for key, value in env.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise Refused("env entries must be strings")
        if not ENV_NAME.match(key) or "\0" in value:
            raise Refused(f"bad environment variable: {key!r}")
        if key in allow:
            kept[key] = value
    config_dir = project.get("claudeConfigDir")
    claimed = env.get("CLAUDE_CONFIG_DIR")
    if isinstance(claimed, str) and claimed.strip():
        if config_dir is None or os.path.realpath(claimed) != os.path.realpath(config_dir):
            raise Refused(f"CLAUDE_CONFIG_DIR {claimed} is not this project's ({config_dir})")
    kept.update(project.get("env", {}))
    kept["HOME"] = project["home"]
    kept["PATH"] = project["path_env"]
    if config_dir:
        kept["CLAUDE_CONFIG_DIR"] = config_dir
    return kept


def build_command(
    registry: dict,
    name: str,
    project: dict,
    cwd: str,
    argv: list[str],
    env: dict[str, str],
    pty: bool,
) -> tuple[str, list[str]]:
    unit = f"agent-{name}-{secrets.token_hex(4)}"
    cmd = [
        registry.get("systemdRun", "systemd-run"),
        "--pty" if pty else "--pipe",
        "--wait",
        "--collect",
        "--quiet",
        f"--unit={unit}",
        f"--description=agent run for project {name}",
        f"--slice=agents-{name}.slice",
        f"--uid={project['user']}",
        f"--gid={project['group']}",
        f"--working-directory={os.path.realpath(cwd)}",
    ]
    cmd += [f"--setenv={k}={v}" for k, v in sorted(env.items())]
    cmd += [f"--property={p}" for p in project.get("properties", [])]
    cmd += ["--", *registry.get("commandPrefix", []), *project.get("commandPrefix", []), *argv]
    return unit, cmd


def _read_request(conn: socket.socket) -> tuple[dict, list[int]]:
    """One JSON line plus the three stdio descriptors (sent with the first chunk)."""
    buf = b""
    fds: list[int] = []
    while b"\n" not in buf:
        data, new_fds, _flags, _addr = socket.recv_fds(conn, 65536, 3)
        fds += new_fds
        if not data:
            raise Refused("client closed before sending a request")
        buf += data
        if len(buf) > 4 * 1024 * 1024:
            raise Refused("request too large")
    line, _, _rest = buf.partition(b"\n")
    try:
        request = json.loads(line)
    except json.JSONDecodeError as e:
        raise Refused(f"request is not JSON: {e}") from None
    if not isinstance(request, dict):
        raise Refused("request must be an object")
    if len(fds) != 3:
        raise Refused(f"expected 3 file descriptors, got {len(fds)}")
    return request, fds


def _reply(conn: socket.socket, payload: dict) -> None:
    try:
        conn.sendall(json.dumps(payload).encode() + b"\n")
    except OSError:
        pass


def _log(msg: str) -> None:
    print(f"agent-broker: {msg}", file=sys.stderr, flush=True)


def _stop_unit(systemctl: str, unit: str) -> None:
    subprocess.run([systemctl, "stop", unit], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def serve(conn: socket.socket, registry: dict) -> int:
    request, fds = _read_request(conn)
    try:
        cwd = request.get("cwd")
        name, project = resolve_project(registry, cwd)
        argv = validate_argv(project, request.get("argv"))
        env = filter_env(registry, project, request.get("env", {}))
        pty = bool(request.get("pty", False))
        unit, cmd = build_command(registry, name, project, cwd, argv, env, pty)
    except Refused:
        for fd in fds:
            os.close(fd)
        raise
    peer = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    _log(f"{unit}: project={name} user={project['user']} cwd={cwd} argv0={argv[0]} caller_pid={int.from_bytes(peer[:4], sys.byteorder)}")
    proc = subprocess.Popen(cmd, stdin=fds[0], stdout=fds[1], stderr=fds[2], close_fds=True)
    for fd in fds:
        os.close(fd)
    systemctl = registry.get("systemctl", "systemctl")
    stopped = False
    while proc.poll() is None:
        ready, _, _ = select.select([conn], [], [], 1.0)
        if ready:
            try:
                data = conn.recv(4096)
            except OSError:
                data = b""
            if not data:
                # The wrapper is gone (killed or exited): the unit must not outlive it.
                _log(f"{unit}: control connection closed, stopping")
                _stop_unit(systemctl, unit)
                stopped = True
                try:
                    proc.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    proc.kill()
                break
    code = proc.wait()
    if not stopped:
        _stop_unit(systemctl, unit)  # idempotent; clears a unit that lingers after a signal
    _log(f"{unit}: exit {code}")
    _reply(conn, {"exit": code})
    return code


def main() -> int:
    conn = socket.socket(fileno=0)
    try:
        registry = load_registry()
        return 0 if serve(conn, registry) >= 0 else EXIT_BROKER_ERROR
    except Refused as e:
        _log(f"refused: {e}")
        _reply(conn, {"error": str(e), "exit": EXIT_REFUSED})
        return 0
    except Exception as e:  # noqa: BLE001 - report to the client, never hang it
        _log(f"error: {e!r}")
        _reply(conn, {"error": f"broker error: {e}", "exit": EXIT_BROKER_ERROR})
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
