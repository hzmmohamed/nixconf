#!/usr/bin/env python3
"""agent-git: where an agent stands in git, and the thread-branch push.

The workflow it supports (see "Git" in the agent guidelines): one thread =
one branch = one worktree; a thread finishes by pushing its branch and
opening a PR.

Usage:
    agent-git [status]            one line, e.g. "worktree on branch x (base
                                  main: 2 ahead, 0 behind; not pushed; clean)"
    agent-git hook session-start  Claude Code SessionStart hook
    agent-git hook stop           Claude Code Stop hook: sends the agent back
                                  (once) when its worktree has uncommitted work
    agent-git push [--force-with-lease]
                                  push the current branch to origin (-u);
                                  refuses the default branch, detached HEAD and
                                  plain force. Installed as `agent-push` too.

The main checkout (not a linked worktree) is shared by every thread working
in "local" mode, so the Stop hook never blocks there: its dirty files may
belong to other threads.
"""
import json
import os
import shutil
import subprocess
import sys

GIT_TIMEOUT = 5
PUSH_TIMEOUT = 120
STOP_REASON = (
    "Uncommitted changes in this thread's worktree: commit them (or say in "
    "your reply why they should stay uncommitted)."
)


def _git(cwd, *args, timeout=GIT_TIMEOUT):
    """stdout of `git -C cwd args`, stripped, or None on any failure."""
    try:
        proc = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def default_branch(cwd):
    """origin/HEAD's branch, else a local main/master, else None."""
    ref = _git(cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if ref and "/" in ref:
        return ref.split("/", 1)[1]
    for name in ("main", "master"):
        if _git(cwd, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}") is not None:
            return name
    return None


def info(cwd):
    """A dict describing the repo at cwd, or None when it isn't one."""
    dirs = _git(cwd, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir")
    if dirs is None:
        return None
    git_dir, common_dir = (dirs.splitlines() + ["", ""])[:2]
    branch = _git(cwd, "symbolic-ref", "--quiet", "--short", "HEAD")
    base = default_branch(cwd)
    porcelain = _git(cwd, "status", "--porcelain") or ""
    d = {
        "linked": os.path.realpath(git_dir) != os.path.realpath(common_dir),
        "branch": branch,
        "base": base,
        "uncommitted": len([ln for ln in porcelain.splitlines() if ln.strip()]),
        "ahead": None,
        "behind": None,
        "upstream": None,
    }
    if branch and base and branch != base:
        counts = _git(cwd, "rev-list", "--left-right", "--count", f"{base}...HEAD")
        if counts:
            behind, ahead = counts.split()
            d["ahead"], d["behind"] = int(ahead), int(behind)
    if branch:
        d["upstream"] = _git(cwd, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    return d


def format_status(d):
    if d is None:
        return "not a git repo"
    where = "worktree" if d["linked"] else "main checkout"
    if d["branch"] is None:
        head = "detached HEAD"
    elif d["branch"] == d["base"]:
        head = d["branch"]
    else:
        head = f"branch {d['branch']}"
    parts = []
    if not d["linked"]:
        parts.append("shared with other threads")
    if d["ahead"] is not None:
        parts.append(f"base {d['base']}: {d['ahead']} ahead, {d['behind']} behind")
    if d["branch"] and d["branch"] != d["base"]:
        parts.append(f"pushed to {d['upstream']}" if d["upstream"] else "not pushed")
    n = d["uncommitted"]
    parts.append(f"{n} uncommitted" if n else "clean")
    return f"{where} on {head} ({'; '.join(parts)})"


def _hook_input():
    try:
        data = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def _cmd_hook(kind):
    # Claude hooks must never fail closed: swallow everything, exit 0.
    try:
        data = _hook_input()
        cwd = data.get("cwd") or os.getcwd()
        d = info(cwd)
        if kind == "session-start":
            if d is None:
                return 0
            text = f'Git: {format_status(d)}. See "Git" in your global instructions.'
            print(
                json.dumps(
                    {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": text}}
                )
            )
        elif kind == "stop":
            if data.get("stop_hook_active"):
                return 0
            if (
                d is not None
                and d["linked"]
                and d["branch"]
                and d["branch"] != d["base"]
                and d["uncommitted"] > 0
            ):
                print(json.dumps({"decision": "block", "reason": STOP_REASON}))
    except BaseException:
        pass
    return 0


def _cmd_push(args):
    cwd = os.getcwd()
    lease = False
    for a in args:
        if a == "--force-with-lease":
            lease = True
        else:
            print(
                f"agent-push: refusing argument {a!r} (only --force-with-lease is accepted; "
                "it always pushes the current branch to origin)",
                file=sys.stderr,
            )
            return 2
    d = info(cwd)
    if d is None:
        print("agent-push: not a git repo", file=sys.stderr)
        return 2
    branch = d["branch"]
    if branch is None:
        print("agent-push: detached HEAD; check out the thread's branch first", file=sys.stderr)
        return 2
    if branch in {d["base"], "main", "master"}:
        print(
            f"agent-push: refusing to push {branch!r} (the default branch); "
            "work on a thread branch and open a PR",
            file=sys.stderr,
        )
        return 2
    if _git(cwd, "remote", "get-url", "origin") is None:
        print("agent-push: no 'origin' remote", file=sys.stderr)
        return 2
    cmd = ["git", "-C", cwd, "push", "-u"]
    if lease:
        cmd.append("--force-with-lease")
    cmd += ["origin", f"refs/heads/{branch}:refs/heads/{branch}"]
    try:
        rc = subprocess.run(cmd, timeout=PUSH_TIMEOUT).returncode
    except subprocess.TimeoutExpired:
        print("agent-push: git push timed out", file=sys.stderr)
        return 1
    if rc != 0:
        return rc
    print(f"agent-push: pushed {branch} to origin")
    if shutil.which("gh"):
        try:
            proc = subprocess.run(
                ["gh", "pr", "view", branch, "--json", "url", "--jq", ".url"],
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=20,
            )
            url = proc.stdout.strip() if proc.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            url = ""
        print(f"PR: {url}" if url else "No PR yet: gh pr create --fill (or --title/--body)")
    return 0


def main(argv):
    if not argv or argv == ["status"]:
        print(format_status(info(os.getcwd())))
        return 0
    if argv[0] == "--json" or argv == ["status", "--json"]:
        print(json.dumps(info(os.getcwd())))
        return 0
    if argv[0] == "hook" and len(argv) == 2 and argv[1] in {"session-start", "stop"}:
        return _cmd_hook(argv[1])
    if argv[0] == "push":
        return _cmd_push(argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
