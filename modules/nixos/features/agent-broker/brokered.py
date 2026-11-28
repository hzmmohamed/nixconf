"""agent-brokered: run a command through the agent broker as the project's user.

    agent-brokered <command> [args...]

Runs as the orchestrator user (T3's `binaryPath` points at a wrapper that
calls this). Sends argv, cwd, the environment and its own stdin/stdout/stderr
to the broker socket, then waits. The child's stdio *is* this process's
stdio, so T3 (or a pipeline) talks to the agent directly; this process only
carries the lifetime: when it is signalled or killed, the broker sees the
connection close and stops the unit. The exit status is the child's.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys

SOCKET_ENV = "AGENT_BROKER_SOCKET"
DEFAULT_SOCKET = "/run/agent-broker/sock"


def _die(msg: str, code: int) -> int:
    print(f"agent-brokered: {msg}", file=sys.stderr, flush=True)
    return code


def main(argv: list[str]) -> int:
    if not argv:
        return _die("usage: agent-brokered <command> [args...]", 2)
    path = os.environ.get(SOCKET_ENV, DEFAULT_SOCKET)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError as e:
        return _die(f"cannot reach the broker at {path}: {e.strerror}", 126)

    def on_signal(signum, _frame):
        # Closing the connection is the stop request; the broker does the rest.
        try:
            sock.close()
        finally:
            os._exit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(sig, on_signal)

    request = {
        "argv": argv,
        "cwd": os.getcwd(),
        "env": dict(os.environ),
        "pty": os.isatty(0) and os.isatty(1),
    }
    socket.send_fds(sock, [json.dumps(request).encode() + b"\n"], [0, 1, 2])
    buf = b""
    while b"\n" not in buf:
        data = sock.recv(4096)
        if not data:
            return _die("the broker closed the connection without a result", 126)
        buf += data
    reply = json.loads(buf.partition(b"\n")[0])
    if "error" in reply:
        return _die(reply["error"], int(reply.get("exit", 125)))
    code = int(reply.get("exit", 126))
    return code if code >= 0 else 128 - code  # a negative code is a signal


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
