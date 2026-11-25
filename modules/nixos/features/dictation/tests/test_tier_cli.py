#!/usr/bin/env python3
"""Tests for `dictate tier` (training lab, plan 1): a one-shot privacy tier
override for the next session only.

dictate.sh runs under bash with the preamble the dictation feature normally
generates replaced by test values; `dictate-stream` is a fake that records
its arguments. Needs bash, coreutils, util-linux (flock, setsid), jq.
"""
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "dictate.sh"

PREAMBLE = """set -euo pipefail
cfg_servers=""
cfg_local_socket="$XDG_RUNTIME_DIR/dictate/local.sock"
cfg_stream="$FAKE_STREAM"
cfg_mode=batch
cfg_mode_file="$HOME/mode"
cfg_long_sec=600
cfg_waybar_signal=8
cfg_overlay=0
cfg_tap_ms=300
layout_lang() { echo en; }
"""


class TierOverride(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="dictate-tier-")
        self.args = os.path.join(self.tmp, "args")
        fake = os.path.join(self.tmp, "fake-stream")
        with open(fake, "w") as f:
            f.write(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> {self.args}\n')
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=self.tmp, HOME=self.tmp,
                        FAKE_STREAM=fake, DICTATE_LANG="en")
        self.state = os.path.join(self.tmp, "dictate")

    def dictate(self, *args):
        return subprocess.run(["bash", "-c", PREAMBLE + '. "$0"', str(SCRIPT), *args],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def start_session(self):
        """`dictate toggle` from idle; returns the fake's argv line."""
        for f in ("state", "pid"):
            try:
                os.remove(os.path.join(self.state, f))
            except FileNotFoundError:
                pass
        before = open(self.args).read().count("\n") if os.path.exists(self.args) else 0
        self.assertEqual(self.dictate("toggle").returncode, 0)
        for _ in range(100):
            if os.path.exists(self.args) and open(self.args).read().count("\n") > before:
                break
            time.sleep(0.05)
        return open(self.args).read().splitlines()[-1]

    def test_override_applies_to_one_session(self):
        self.assertEqual(self.dictate("tier", "work").returncode, 0)
        self.assertIn("--tier work", self.start_session())
        self.assertFalse(os.path.exists(os.path.join(self.state, "tier")))
        self.assertNotIn("--tier", self.start_session())

    def test_auto_clears_override(self):
        self.dictate("tier", "personal")
        self.dictate("tier", "auto")
        self.assertNotIn("--tier", self.start_session())

    def test_bad_value_is_rejected(self):
        r = self.dictate("tier", "bogus")
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage: dictate tier", r.stderr)


if __name__ == "__main__":
    unittest.main()
