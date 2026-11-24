#!/usr/bin/env python3
"""Tests for agent_git.py: status line, the SessionStart/Stop hooks, and
`push` (agent-push). Each test builds a throwaway repo with a bare "origin"
and a linked worktree, then runs the real script as a subprocess.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "agent_git.py"


def git(cwd, *args, env=None):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=env)


class AgentGitTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.env = dict(os.environ)
        self.env.update(
            HOME=str(tmp),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="t",
            GIT_AUTHOR_EMAIL="t@t",
            GIT_COMMITTER_NAME="t",
            GIT_COMMITTER_EMAIL="t@t",
            # No gh in tests: push output must not depend on it.
            PATH=os.pathsep.join(
                p for p in self.env.get("PATH", "").split(os.pathsep) if not (Path(p) / "gh").exists()
            ),
        )
        self.origin = tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], check=True, env=self.env)
        self.main = tmp / "main"
        subprocess.run(
            ["git", "clone", "-q", str(self.origin), str(self.main)], check=True, capture_output=True, env=self.env
        )
        self.git(self.main, "checkout", "-q", "-b", "main")
        (self.main / "a.txt").write_text("a\n")
        self.git(self.main, "add", "a.txt")
        self._commit(self.main, "init")
        self.git(self.main, "push", "-q", "-u", "origin", "main")
        self.git(self.main, "remote", "set-head", "origin", "main")
        self.wt = tmp / "wt"
        self.git(self.main, "worktree", "add", "-q", "-b", "thread-x", str(self.wt))

    def git(self, cwd, *args):
        git(cwd, *args, env=self.env)

    def _commit(self, cwd, msg):
        subprocess.run(["git", "-C", str(cwd), "commit", "-q", "-m", msg], check=True, env=self.env)

    def run_script(self, *args, cwd, stdin=""):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=str(cwd),
            input=stdin,
            capture_output=True,
            text=True,
            timeout=30,
            env=self.env,
        )

    # status

    def test_status_main_checkout(self):
        (self.main / "dirty.txt").write_text("x\n")
        r = self.run_script("status", cwd=self.main)
        self.assertEqual(r.stdout.strip(), "main checkout on main (shared with other threads; 1 uncommitted)")

    def test_status_worktree(self):
        (self.wt / "b.txt").write_text("b\n")
        self.git(self.wt, "add", "b.txt")
        self._commit(self.wt, "b")
        r = self.run_script(cwd=self.wt)
        self.assertEqual(
            r.stdout.strip(),
            "worktree on branch thread-x (base main: 1 ahead, 0 behind; not pushed; clean)",
        )

    def test_status_not_a_repo(self):
        r = self.run_script(cwd=Path(self._tmp.name))
        self.assertEqual(r.stdout.strip(), "not a git repo")

    # hooks

    def test_session_start_context(self):
        r = self.run_script("hook", "session-start", cwd=self.wt, stdin=json.dumps({"cwd": str(self.wt)}))
        out = json.loads(r.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "SessionStart")
        self.assertTrue(out["additionalContext"].startswith("Git: worktree on branch thread-x"))
        self.assertIn('See "Git" in your global instructions.', out["additionalContext"])

    def test_stop_blocks_dirty_worktree(self):
        (self.wt / "new.txt").write_text("n\n")
        r = self.run_script("hook", "stop", cwd=self.wt, stdin=json.dumps({"cwd": str(self.wt)}))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(json.loads(r.stdout)["decision"], "block")

    def test_stop_ignores_gitignored(self):
        (self.wt / ".gitignore").write_text("build/\n")
        self.git(self.wt, "add", ".gitignore")
        self._commit(self.wt, "ignore")
        (self.wt / "build").mkdir()
        (self.wt / "build" / "out").write_text("o\n")
        r = self.run_script("hook", "stop", cwd=self.wt, stdin="{}")
        self.assertEqual(r.stdout, "")

    def test_stop_silent_when_active_or_clean_or_main(self):
        (self.wt / "new.txt").write_text("n\n")
        r = self.run_script("hook", "stop", cwd=self.wt, stdin=json.dumps({"stop_hook_active": True}))
        self.assertEqual(r.stdout, "")
        (self.main / "dirty.txt").write_text("x\n")
        r = self.run_script("hook", "stop", cwd=self.main, stdin="{}")
        self.assertEqual(r.stdout, "")
        (self.wt / "new.txt").unlink()
        r = self.run_script("hook", "stop", cwd=self.wt, stdin="{}")
        self.assertEqual(r.stdout, "")

    def test_hook_never_fails(self):
        r = self.run_script("hook", "stop", cwd=self.wt, stdin="not json")
        self.assertEqual(r.returncode, 0)

    # push

    def test_push_refuses_main_and_force(self):
        r = self.run_script("push", cwd=self.main)
        self.assertEqual(r.returncode, 2)
        self.assertIn("default branch", r.stderr)
        for bad in ("-f", "--force", "+thread-x", "origin", "main"):
            r = self.run_script("push", bad, cwd=self.wt)
            self.assertEqual(r.returncode, 2, bad)

    def test_push_thread_branch(self):
        (self.wt / "b.txt").write_text("b\n")
        self.git(self.wt, "add", "b.txt")
        self._commit(self.wt, "b")
        r = self.run_script("push", cwd=self.wt)
        self.assertEqual(r.returncode, 0, r.stderr)
        heads = subprocess.run(
            ["git", "-C", str(self.origin), "branch", "--list"], capture_output=True, text=True
        ).stdout
        self.assertIn("thread-x", heads)
        r = self.run_script(cwd=self.wt)
        self.assertIn("pushed to origin/thread-x", r.stdout)


if __name__ == "__main__":
    unittest.main()
