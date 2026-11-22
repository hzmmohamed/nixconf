#!/usr/bin/env python3
"""Tests for agent_net.py's `hook session-start` / `hook prompt` subcommands
(Claude Code SessionStart / UserPromptSubmit hooks).

Every test fakes `ip`/`nmcli` with fakebin.FakeBin and invokes the real
script as a subprocess, feeding Claude's hook JSON on stdin.
"""
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fakebin import FakeBin  # noqa: E402

SCRIPT = Path(__file__).parent.parent / "agent_net.py"


class AgentNetHookTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.fake = FakeBin(self.tmpdir)
        self.runtime_dir = self.tmpdir / "runtime"
        self.env = self.fake.env(XDG_RUNTIME_DIR=str(self.runtime_dir))

    def _add_metered(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="yes (guessed)\nwildflower\n")

    def _switch_to_unmetered_home(self):
        self.fake.add("nmcli", stdout="no\nhome\n")

    def test_session_start_emits_context(self):
        self._add_metered()
        result = self.fake.run(
            SCRIPT, "hook", "session-start", stdin='{"session_id":"s1"}', env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(
            data["hookSpecificOutput"]["hookEventName"], "SessionStart"
        )
        self.assertEqual(
            data["hookSpecificOutput"]["additionalContext"],
            'Network: metered (wildflower, wlo1). See "Network" in your global instructions.',
        )

    def test_prompt_silent_when_unchanged(self):
        self._add_metered()
        self.fake.run(
            SCRIPT, "hook", "session-start", stdin='{"session_id":"s1"}', env=self.env
        )
        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s1"}', env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_prompt_reports_change(self):
        self._add_metered()
        self.fake.run(
            SCRIPT, "hook", "session-start", stdin='{"session_id":"s1"}', env=self.env
        )
        self._switch_to_unmetered_home()

        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s1"}', env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(
            data["hookSpecificOutput"]["additionalContext"],
            "Network changed: now unmetered (home, wlo1).",
        )

        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s1"}', env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_prompt_unknown_session_stores_silently(self):
        self._add_metered()
        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s9"}', env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue((self.runtime_dir / "agent-net" / "s9").exists())

    def test_hook_survives_garbage_stdin(self):
        self._add_metered()
        result = self.fake.run(SCRIPT, "hook", "prompt", stdin="not json", env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_hook_survives_slow_nmcli(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="no\nhome\n", sleep=5)
        start = time.monotonic()
        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s9"}', env=self.env
        )
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        # The hook's own budget (HOOK_TIMEOUT=0.25s per call, at most two
        # calls) must bound this, not the 5s the fake nmcli sleeps for.
        self.assertLess(elapsed, 1.0)
        # A status that timed out is "undetermined", not "offline": it must
        # not be stored, or the next prompt would see a bogus transition
        # into/out of "offline" once the real state is read.
        self.assertFalse((self.runtime_dir / "agent-net" / "s9").exists())

    def test_prompt_fast_path_latency(self):
        self._add_metered()
        start = time.monotonic()
        result = self.fake.run(
            SCRIPT, "hook", "prompt", stdin='{"session_id":"s-fast"}', env=self.env
        )
        elapsed = time.monotonic() - start
        self.assertEqual(result.returncode, 0, result.stderr)
        # Loose bound (interpreter startup + two fast fake subprocesses)
        # so this doesn't flake, but it does catch a budget regression.
        self.assertLess(elapsed, 0.5)


if __name__ == "__main__":
    unittest.main()
