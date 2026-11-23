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
  not-built   - allowed, but the dev shell isn't cached yet (or `direnv
                export json` timed out -- see below). BINARY runs bare; on
                an unmetered connection a background warm-up (`systemd-run
                ... direnv exec <root> true`) is kicked off so the next run
                can be `loaded`.
  loaded      - allowed and cached: `direnv export json` ran at `root`, its
                output was applied to BINARY's environment, and BINARY runs
                with that environment (no subprocess in between -- we
                os.execvpe BINARY ourselves). If the export call itself
                fails or answers with something unparseable, that's
                `error`; if it times out, that's `not-built` (the dev shell
                may be mid-rebuild), its whole process group is killed (no
                background `nix print-dev-env` left fetching) and no
                warm-up is fired for it.
  error       - something in the logic above raised, or `direnv export
                json` failed/answered with bad JSON; BINARY runs bare.

Root resolution: nearest ancestor of cwd (inclusive) with a `.envrc`,
stopping before (and not including) $HOME or `/`.

Worktree exception: when `root` is a linked git worktree (its
`--git-common-dir` is not `<root>/.git` AND the main checkout lists it in
`git worktree list`, so a forged `.git` file doesn't qualify), its own
`.envrc` is merely not yet allowed (never one the user explicitly denied),
and its main checkout's `.envrc` is both allowed and byte-identical, this
script auto-allows the worktree root (`direnv allow <root>`) rather than
reporting not-allowed, and considers the
worktree cached whenever the main checkout is cached and the shell-defining
files are byte-identical between the two (no seeding: direnv re-evaluates
locally against store paths the main checkout already roots). The main
root is resolved with `git rev-parse --path-format=absolute ...` (plain
`--show-toplevel --git-common-dir` prints `--git-common-dir` *relative to
the `-C` directory*, not the toplevel -- from a subdirectory that silently
points at the wrong tree) and computed once per run, reused for both the
allow check and the cache check.
"""
import hashlib
import json
import os
import signal
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


EXPORT_TIMEOUT_ENV = "AGENT_DEVSHELL_EXPORT_TIMEOUT"
DEFAULT_EXPORT_TIMEOUT = 20.0


def _run(args, timeout=10, cwd=None, env=None):
    """Run an external tool. None on any failure to launch/timeout/decode --
    every caller treats that the same as a hard "no" (never raises)."""
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env
        )
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError):
        return None


def _export_timeout() -> float:
    """20s by default; $AGENT_DEVSHELL_EXPORT_TIMEOUT overrides it (tests
    only -- lets a timeout test run in well under a second)."""
    raw = os.environ.get(EXPORT_TIMEOUT_ENV)
    if raw:
        try:
            return float(raw)
        except ValueError:
            pass
    return DEFAULT_EXPORT_TIMEOUT


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


# direnv's AllowStatus values (foundRC.allowed in `direnv status --json`).
ALLOWED, NOT_ALLOWED, DENIED = 0, 1, 2


def _allow_status(status):
    """foundRC.allowed (ALLOWED/NOT_ALLOWED/DENIED), or None when there's
    no usable foundRC."""
    if not isinstance(status, dict):
        return None
    found = (status.get("state") or {}).get("foundRC")
    if not isinstance(found, dict):
        return None
    return found.get("allowed")


def _is_allowed(status) -> bool:
    return _allow_status(status) == ALLOWED


def _git_common_dir(root: Path):
    """(toplevel, common_dir) from `git -C root rev-parse
    --path-format=absolute --show-toplevel --git-common-dir`, or None if
    git failed / output didn't parse. `--path-format=absolute` is required:
    plain `--git-common-dir` prints a path *relative to the `-C` directory*
    (root), not to the toplevel -- from a subdirectory that silently
    resolves to the wrong tree if naively joined against toplevel."""
    proc = _run(
        [
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--git-common-dir",
        ]
    )
    if proc is None or proc.returncode != 0:
        return None
    lines = proc.stdout.strip().splitlines()
    if len(lines) != 2:
        return None
    return Path(lines[0]), Path(lines[1])


def _registered_worktrees(main_toplevel: Path):
    """Resolved paths of the worktrees `main_toplevel` itself has
    registered (`git worktree list --porcelain`), or an empty set if git
    failed."""
    proc = _run(["git", "-C", str(main_toplevel), "worktree", "list", "--porcelain"])
    if proc is None or proc.returncode != 0:
        return set()
    paths = set()
    for line in proc.stdout.splitlines():
        if line.startswith("worktree "):
            paths.add(Path(line[len("worktree ") :]).resolve())
    return paths


def _worktree_main_root(root: Path):
    """The corresponding path in the main checkout if `root` is a linked
    worktree, else None: not a git repo, git failed, it IS the main
    checkout (common-dir == <toplevel>/.git), the main checkout hasn't
    registered `root`'s toplevel as one of its worktrees, or the computed
    main-checkout path doesn't exist (a worktree subdirectory with no
    counterpart in the main tree, e.g. untracked/uncommitted there).

    The registration check matters: any directory with a one-line `.git`
    file (`gitdir: <main>/.git`) makes `rev-parse` report it as a linked
    worktree of <main>. Only `git worktree list` run in the main checkout
    (which reads <main>/.git/worktrees, not anything under `root`) tells a
    real `git worktree add` from such a forgery."""
    got = _git_common_dir(root)
    if got is None:
        return None
    toplevel, common_dir = got  # both absolute (--path-format=absolute)
    toplevel, common_dir = toplevel.resolve(), common_dir.resolve()
    if common_dir == (toplevel / ".git"):
        return None  # the main checkout, not a worktree
    main_toplevel = common_dir.parent
    if toplevel not in _registered_worktrees(main_toplevel):
        return None  # not a worktree main knows about (e.g. a forged .git file)
    try:
        rel = root.resolve().relative_to(toplevel)
    except ValueError:
        rel = Path(".")
    main_root = main_toplevel / rel
    return main_root if main_root.is_dir() else None


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


def _try_worktree_auto_allow(root: Path, main_root, root_status) -> bool:
    """The worktree exception: if `root`'s `.envrc` is merely not yet
    allowed (never explicitly denied), its main checkout is allowed and the
    `.envrc` is byte-identical, `direnv allow root` and report allowed."""
    if main_root is None:
        return False
    if _allow_status(root_status) != NOT_ALLOWED:
        return False  # a `direnv deny` is the user's call; never override it
    if not _is_allowed(_direnv_status(main_root)):
        return False
    if not _files_identical(root / ".envrc", main_root / ".envrc"):
        return False
    proc = _run(["direnv", "allow", str(root)])
    return proc is not None and proc.returncode == 0


def _check_allowed(root: Path, main_root) -> bool:
    status = _direnv_status(root)
    if _is_allowed(status):
        return True
    return _try_worktree_auto_allow(root, main_root, status)


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


def _is_cached(root: Path, main_root) -> bool:
    if _profile_cached_locally(root):
        return True
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
    digest = hashlib.sha1(os.fsencode(root)).hexdigest()[:12]
    unit = f"agent-devshell-warm-{digest}"
    # The unit runs under the user manager, which doesn't inherit our
    # environment: without DIRENV_CONFIG (the wrapper defaults it to
    # /etc/direnv) direnv falls back to its built-in use_flake, whose
    # layout never makes the next start "cached".
    setenv = []
    if os.environ.get("DIRENV_CONFIG"):
        setenv = [f"--setenv=DIRENV_CONFIG={os.environ['DIRENV_CONFIG']}"]
    _run(
        [
            "systemd-run",
            "--user",
            "--collect",
            "--quiet",
            "--unit",
            unit,
            *setenv,
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


def _direnv_export(root: Path):
    """Run `direnv export json` at `root`. Returns one of:
      ("ok", {var: value_or_None})  -- parsed export (value None = unset)
      ("timeout", None)             -- the call itself timed out
      ("error", None)               -- nonzero exit / unparseable output

    `DIRENV_LOG_FORMAT=""` keeps direnv's own log noise off stderr/stdout so
    it can't be mistaken for part of the JSON."""
    env = dict(os.environ)
    env["DIRENV_LOG_FORMAT"] = ""
    try:
        # Own session/process group: on timeout the whole group (direnv,
        # its bash, `nix print-dev-env`) is killed, not just direnv --
        # otherwise a build/download keeps running in the background.
        proc = subprocess.Popen(
            ["direnv", "export", "json"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=str(root),
            env=env,
            start_new_session=True,
        )
    except OSError:
        return "error", None
    try:
        stdout, _ = proc.communicate(timeout=_export_timeout())
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return "timeout", None
    except (OSError, UnicodeDecodeError):
        _kill_group(proc)
        return "error", None

    if proc.returncode != 0:
        return "error", None

    out = (stdout or "").strip()
    if not out:
        return "ok", {}  # no changes
    try:
        data = json.loads(out)
    except ValueError:
        return "error", None
    if not isinstance(data, dict):
        return "error", None
    return "ok", data


def _kill_group(proc) -> None:
    """SIGKILL `proc`'s whole process group (it leads its own session),
    then reap it. Never raises."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass
    for pipe in (proc.stdout, proc.stderr):
        try:
            if pipe is not None:
                pipe.close()
        except OSError:
            pass


def _exec_loaded(root: Path, binary: str, args: list) -> None:
    """Apply `direnv export json`'s output to a copy of our own environment
    and os.execvpe BINARY directly -- no `direnv exec` subprocess in
    between, so a hung/failing direnv can't block or wrap thread start."""
    status, data = _direnv_export(root)
    if status == "timeout":
        # The dev shell looked cached a moment ago; a hang here means
        # something's off (e.g. a concurrent rebuild), not "never built".
        # Don't fire a warm-up for this -- it's not the "not yet built"
        # case the warm-up exists for.
        _exec_bare("not-built", binary, args)
        return
    if status != "ok":
        _exec_bare("error", binary, args)
        return

    env = dict(os.environ)
    for key, value in data.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    env[AGENT_DEVSHELL_ENV] = "loaded"
    os.execvpe(binary, [binary, *args], env)


def _decide_and_exec(binary: str, args: list) -> None:
    root = _find_root(Path.cwd())
    if root is None:
        _exec_bare("none", binary, args)
        return

    # Computed once and reused for both the allow check and the cache
    # check, instead of shelling out to git twice for the same answer.
    main_root = _worktree_main_root(root)

    if not _check_allowed(root, main_root):
        _exec_bare("not-allowed", binary, args)
        return

    if _is_cached(root, main_root):
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
