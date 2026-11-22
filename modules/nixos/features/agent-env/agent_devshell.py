#!/usr/bin/env python3
"""agent-devshell: run BINARY inside the project's direnv dev shell, when
one is cached and allowed; otherwise run BINARY bare. Used to wrap T3 Code's
Claude/OpenCode providers so threads start with the project's tools on PATH.

Usage: agent-devshell BINARY [ARGS...]

This must never fail closed: whatever happens, BINARY ends up exec'd (via
os.execvpe/os.execvp) with the same ARGS it was given. The only thing that
varies is the AGENT_DEVSHELL environment variable BINARY sees, one of:

  none        - no .envrc between cwd and $HOME/"/".
  not-allowed - a .envrc exists but direnv hasn't allowed it (and the
                worktree auto-allow exception below doesn't apply).
  not-built   - allowed, but the dev shell isn't cached yet. BINARY runs
                bare; on an unmetered connection a background warm-up
                (`systemd-run ... direnv exec <root> true`) is kicked off
                so the next run can be `loaded`.
  loaded      - allowed and cached: BINARY runs under `direnv exec <root>`.
  error       - something in the logic above raised; BINARY runs bare.

Root resolution: nearest ancestor of cwd (inclusive) with a `.envrc`,
stopping before (and not including) $HOME or `/`.

Worktree exception: when `root` is a linked git worktree (its
`--git-common-dir` is not `<root>/.git`) and its main checkout's `.envrc` is
both allowed and byte-identical, this script auto-allows the worktree root
(`direnv allow <root>`) rather than reporting not-allowed, and considers the
worktree cached whenever the main checkout is cached and the shell-defining
files are byte-identical between the two (no seeding: direnv re-evaluates
locally against store paths the main checkout already roots).
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

AGENT_DEVSHELL_ENV = "AGENT_DEVSHELL"

# Files whose presence/mtime/content decide whether a cached dev-shell
# profile is still fresh.
SHELL_FILES = [
    "flake.nix",
    "flake.lock",
    ".envrc",
    "devenv.nix",
    "devenv.yaml",
    "devenv.lock",
]


def _run(args, timeout=10, cwd=None):
    """Run an external tool. None on any failure to launch/timeout -- every
    caller treats that the same as a hard "no" (never raises)."""
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, cwd=cwd
        )
    except (OSError, subprocess.TimeoutExpired):
        return None


def _find_root(start: Path):
    """Nearest ancestor of `start` (inclusive) with a `.envrc`, never
    checking $HOME or `/` itself."""
    home = Path(os.environ.get("HOME") or str(Path.home())).resolve()
    cur = start.resolve()
    while cur != home and cur != cur.parent:
        if (cur / ".envrc").is_file():
            return cur
        cur = cur.parent
    return None


def _direnv_status(root: Path):
    """Deliberately not wrapped in a try/except: a direnv that's missing,
    times out, or answers with something that isn't the expected JSON is
    exactly the kind of surprise the top-level catch-all in main() exists
    for (-> AGENT_DEVSHELL=error, BINARY still runs). git's equivalent
    lookup (_git_common_dir) stays graceful instead, because "this isn't a
    git repo" / "no worktree" is an expected, common outcome, not a
    surprise."""
    proc = subprocess.run(
        ["direnv", "status", "--json"],
        capture_output=True,
        text=True,
        timeout=10,
        cwd=str(root),
    )
    return json.loads(proc.stdout)


def _is_allowed(status) -> bool:
    if not isinstance(status, dict):
        return False
    found = (status.get("state") or {}).get("foundRC")
    return isinstance(found, dict) and found.get("allowed") == 0


def _git_common_dir(root: Path):
    """(toplevel, common_dir) from `git -C root rev-parse --show-toplevel
    --git-common-dir`, or None if git failed / output didn't parse."""
    proc = _run(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel", "--git-common-dir"]
    )
    if proc is None or proc.returncode != 0:
        return None
    lines = proc.stdout.strip().splitlines()
    if len(lines) != 2:
        return None
    return Path(lines[0]), Path(lines[1])


def _worktree_main_root(root: Path):
    """The corresponding path in the main checkout if `root` is a linked
    worktree, else None (not a git repo, git failed, or it IS the main
    checkout: common-dir == <toplevel>/.git)."""
    got = _git_common_dir(root)
    if got is None:
        return None
    toplevel, common_dir = got
    toplevel = toplevel.resolve()
    common_dir = common_dir if common_dir.is_absolute() else (toplevel / common_dir)
    common_dir = common_dir.resolve()
    if common_dir == (toplevel / ".git"):
        return None  # the main checkout, not a worktree
    main_toplevel = common_dir.parent
    try:
        rel = root.resolve().relative_to(toplevel)
    except ValueError:
        rel = Path(".")
    return main_toplevel / rel


def _files_identical(a: Path, b: Path) -> bool:
    a_exists, b_exists = a.is_file(), b.is_file()
    if a_exists != b_exists:
        return False
    if not a_exists:
        return True
    try:
        return a.read_bytes() == b.read_bytes()
    except OSError:
        return False


def _try_worktree_auto_allow(root: Path) -> bool:
    """The worktree exception: if `root`'s main checkout is allowed and its
    `.envrc` is byte-identical, `direnv allow root` and report allowed."""
    main_root = _worktree_main_root(root)
    if main_root is None:
        return False
    if not _is_allowed(_direnv_status(main_root)):
        return False
    if not _files_identical(root / ".envrc", main_root / ".envrc"):
        return False
    proc = _run(["direnv", "allow", str(root)])
    return proc is not None and proc.returncode == 0


def _check_allowed(root: Path) -> bool:
    if _is_allowed(_direnv_status(root)):
        return True
    return _try_worktree_auto_allow(root)


def _profile_cached_locally(root: Path) -> bool:
    """Some `.direnv/flake-profile-*` symlink resolves to an existing path
    and its `.rc` file is newer than every existing shell-defining file in
    `root`."""
    direnv_dir = root / ".direnv"
    if not direnv_dir.is_dir():
        return False

    shell_files = [root / f for f in SHELL_FILES if (root / f).is_file()]

    try:
        entries = sorted(direnv_dir.glob("flake-profile-*"))
    except OSError:
        return False

    for link in entries:
        if link.name.endswith(".rc"):
            continue
        rc = direnv_dir / (link.name + ".rc")
        if not rc.is_file():
            continue
        try:
            if not link.resolve().exists():
                continue
            rc_mtime = rc.stat().st_mtime
        except OSError:
            continue
        if all(rc_mtime > f.stat().st_mtime for f in shell_files):
            return True
    return False


def _is_cached(root: Path) -> bool:
    if _profile_cached_locally(root):
        return True
    main_root = _worktree_main_root(root)
    if main_root is None:
        return False
    if not _profile_cached_locally(main_root):
        return False
    return all(_files_identical(root / f, main_root / f) for f in SHELL_FILES)


def _agent_net_unmetered() -> bool:
    """Same fallback as nx: missing/failing/bad JSON -> unmetered."""
    proc = _run(["agent-net", "--json"], timeout=5)
    if proc is None or proc.returncode != 0:
        return True
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return True
    if not isinstance(data, dict):
        return True
    return data.get("state") != "metered"


def _warm_up(root: Path) -> None:
    digest = hashlib.sha1(str(root).encode()).hexdigest()[:12]
    unit = f"agent-devshell-warm-{digest}"
    _run(
        [
            "systemd-run",
            "--user",
            "--collect",
            "--quiet",
            "--unit",
            unit,
            "--",
            "direnv",
            "exec",
            str(root),
            "true",
        ]
    )


def _exec_bare(state: str, binary: str, args: list) -> None:
    os.environ[AGENT_DEVSHELL_ENV] = state
    os.execvp(binary, [binary, *args])


def _exec_loaded(root: Path, binary: str, args: list) -> None:
    os.environ[AGENT_DEVSHELL_ENV] = "loaded"
    os.execvp("direnv", ["direnv", "exec", str(root), binary, *args])


def _decide_and_exec(binary: str, args: list) -> None:
    root = _find_root(Path.cwd())
    if root is None:
        _exec_bare("none", binary, args)
        return

    if not _check_allowed(root):
        _exec_bare("not-allowed", binary, args)
        return

    if _is_cached(root):
        _exec_loaded(root, binary, args)
        return

    if _agent_net_unmetered():
        _warm_up(root)
    _exec_bare("not-built", binary, args)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if not argv:
        print("usage: agent-devshell BINARY [ARGS...]", file=sys.stderr)
        return 2

    binary, args = argv[0], argv[1:]

    try:
        _decide_and_exec(binary, args)
        return 0  # unreachable: _decide_and_exec always execs or raises
    except BaseException:
        # Never fail closed: whatever went wrong, still run BINARY.
        try:
            _exec_bare("error", binary, args)
        except BaseException:
            os.execvp(binary, [binary, *args])
        return 0


if __name__ == "__main__":
    sys.exit(main())
