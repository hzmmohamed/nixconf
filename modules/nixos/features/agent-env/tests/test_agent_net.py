#!/usr/bin/env python3
"""Tests for agent_net.py — run via `python3 -m unittest discover`.

Every test fakes `ip`/`nmcli` with fakebin.FakeBin and invokes the real
script as a subprocess, so the test exercises the actual CLI (argv parsing,
stdout formatting, --json, `set`), not just the importable status() helper.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fakebin import FakeBin  # noqa: E402

SCRIPT = Path(__file__).parent.parent / "agent_net.py"


class AgentNetTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.fake = FakeBin(self.tmpdir)

    def test_metered_hotspot(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="yes (guessed)\nwildflower\n")

        result = self.fake.run(SCRIPT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "metered (wildflower, wlo1)\n")

        result = self.fake.run(SCRIPT, "--json")
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "metered")
        self.assertEqual(data["source"], "nm")

    def test_unmetered_guessed(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="no (guessed)\nhome\n")

        result = self.fake.run(SCRIPT)
        self.assertEqual(result.stdout, "unmetered (home, wlo1)\n")

    def test_unknown_is_unmetered(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="unknown\nfoo\n")

        result = self.fake.run(SCRIPT, "--json")
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "unmetered")

    def test_lowest_metric_route_wins(self):
        self.fake.add(
            "ip",
            stdout=json.dumps(
                [
                    {"dst": "default", "dev": "wlo1", "metric": 600},
                    {"dst": "default", "dev": "eno2", "metric": 100},
                ]
            ),
        )
        self.fake.add("nmcli", stdout="no\neno2\n")

        result = self.fake.run(SCRIPT, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.fake.calls("nmcli")
        self.assertEqual(len(calls), 1)
        self.assertIn("eno2", calls[0])

    def test_offline(self):
        self.fake.add("ip", stdout="[]")

        result = self.fake.run(SCRIPT, "--json")
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "offline")
        self.assertIsNone(data["connection"])

    def test_no_nmcli(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        # No fake nmcli added: it is not on PATH.

        result = self.fake.run(SCRIPT, "--json")
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "unmetered")
        self.assertEqual(data["source"], "none")

    def test_override(self):
        self.fake.add(
            "ip",
            stdout=json.dumps([{"dst": "default", "dev": "wlo1", "metric": 600}]),
        )
        self.fake.add("nmcli", stdout="no\nhome\n")
        state_home = self.tmpdir / "state"
        env = self.fake.env(XDG_STATE_HOME=str(state_home))

        result = self.fake.run(SCRIPT, "set", "metered", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)

        result = self.fake.run(SCRIPT, "--json", env=env)
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "metered")
        self.assertEqual(data["source"], "override")

        result = self.fake.run(SCRIPT, "set", "auto", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((state_home / "agent-net" / "override").exists())

        result = self.fake.run(SCRIPT, "--json", env=env)
        data = json.loads(result.stdout)
        self.assertEqual(data["state"], "unmetered")

    def test_set_rejects_bad_value(self):
        result = self.fake.run(SCRIPT, "set", "foo")
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
