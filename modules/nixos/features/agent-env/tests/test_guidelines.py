#!/usr/bin/env python3
"""Tests for the global agent guidelines: `guidelines.md` (content shape) and
`guidelines-import.sh` (the Claude CLAUDE.md import-line activation step).

The importer is plain bash (packaged as a `writeShellApplication` in
agent-env.nix), so it is run directly with `bash`, not via `sys.executable`
like the Python tools in this directory.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AGENT_ENV_DIR = Path(__file__).parent.parent
GUIDELINES = AGENT_ENV_DIR / "guidelines.md"
IMPORT_SCRIPT = AGENT_ENV_DIR / "guidelines-import.sh"
IMPORT_LINE = "@~/.config/agents/guidelines.md"

REQUIRED_HEADINGS = [
    "Environment",
    "Tools (nx)",
    "Network",
    "Editing",
]


class GuidelinesContentTests(unittest.TestCase):
    def test_sections_and_import_line(self):
        text = GUIDELINES.read_text()
        lines = text.splitlines()
        self.assertLessEqual(len(lines), 60, "guidelines.md should stay short")

        headings = re.findall(r"^##\s+(.+?)\s*$", text, re.MULTILINE)
        self.assertEqual(headings, REQUIRED_HEADINGS)

        for token in ("AGENT_DEVSHELL", "direnv exec .", "nx", "agent-net"):
            self.assertIn(token, text, f"guidelines.md should mention {token!r}")


class ImportScriptTests(unittest.TestCase):
    def run_import(self, home, *dirs):
        env = dict(os.environ)
        env["HOME"] = str(home)
        return subprocess.run(
            ["bash", str(IMPORT_SCRIPT), *dirs],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )

    def test_import_idempotent_missing_file(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            result = self.run_import(home, ".claude")
            self.assertEqual(result.returncode, 0, result.stderr)
            claude_md = home / ".claude" / "CLAUDE.md"
            self.assertTrue(claude_md.exists())
            self.assertEqual(claude_md.read_text().count(IMPORT_LINE), 1)

            result = self.run_import(home, ".claude")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(claude_md.read_text().count(IMPORT_LINE), 1)

    def test_import_idempotent_existing_file_no_trailing_newline(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            claude_dir = home / ".claude"
            claude_dir.mkdir(parents=True)
            claude_md = claude_dir / "CLAUDE.md"
            user_text = "# My notes\n\nSome existing instructions, no trailing newline."
            claude_md.write_text(user_text)

            result = self.run_import(home, ".claude")
            self.assertEqual(result.returncode, 0, result.stderr)
            content = claude_md.read_text()
            self.assertIn(user_text, content)
            self.assertEqual(content.count(IMPORT_LINE), 1)

            result = self.run_import(home, ".claude")
            self.assertEqual(result.returncode, 0, result.stderr)
            content_again = claude_md.read_text()
            self.assertIn(user_text, content_again)
            self.assertEqual(content_again.count(IMPORT_LINE), 1)
            self.assertEqual(content, content_again)

    def test_multiple_dirs(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            result = self.run_import(home, ".claude", ".claude-work")
            self.assertEqual(result.returncode, 0, result.stderr)
            for d in (".claude", ".claude-work"):
                md = home / d / "CLAUDE.md"
                self.assertEqual(md.read_text().count(IMPORT_LINE), 1)


if __name__ == "__main__":
    unittest.main()
