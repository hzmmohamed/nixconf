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
    "Git",
    "Editing",
]


class GuidelinesContentTests(unittest.TestCase):
    def test_sections_and_import_line(self):
        text = GUIDELINES.read_text()
        lines = text.splitlines()
        self.assertLessEqual(len(lines), 80, "guidelines.md should stay short")

        headings = re.findall(r"^##\s+(.+?)\s*$", text, re.MULTILINE)
        self.assertEqual(headings, REQUIRED_HEADINGS)

        for token in ("AGENT_DEVSHELL", "direnv exec .", "nx", "agent-net", "agent-push", "gh pr create"):
            self.assertIn(token, text, f"guidelines.md should mention {token!r}")

        for value in ("loaded", "not-allowed", "not-built", "none", "error"):
            self.assertIn(
                f"`{value}`",
                text,
                f"guidelines.md should cover $AGENT_DEVSHELL={value!r}",
            )


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

    def test_import_line_with_trailing_whitespace_not_duplicated(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            claude_dir = home / ".claude"
            claude_dir.mkdir(parents=True)
            claude_md = claude_dir / "CLAUDE.md"
            # A user-edited line with trailing spaces should still count as
            # "already present" and not get a duplicate appended.
            claude_md.write_text(f"{IMPORT_LINE}   \n")

            result = self.run_import(home, ".claude")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(claude_md.read_text().count(IMPORT_LINE), 1)

    def test_symlinked_claude_md_untouched(self):
        """I6: a CLAUDE.md that is a symlink (e.g. into the store, managed
        elsewhere) is left alone with a warning; activation must not fail."""
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            target = home / "managed-CLAUDE.md"
            target.write_text("# managed elsewhere\n")
            claude_dir = home / ".claude"
            claude_dir.mkdir()
            (claude_dir / "CLAUDE.md").symlink_to(target)

            result = self.run_import(home, ".claude", ".claude-work")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((claude_dir / "CLAUDE.md").is_symlink())
            self.assertEqual(target.read_text(), "# managed elsewhere\n")
            self.assertIn("CLAUDE.md", result.stderr)
            # The other account is still handled.
            other = home / ".claude-work" / "CLAUDE.md"
            self.assertEqual(other.read_text().count(IMPORT_LINE), 1)

    @unittest.skipIf(os.geteuid() == 0, "root ignores file permissions")
    def test_read_only_claude_md_untouched(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            claude_dir = home / ".claude"
            claude_dir.mkdir()
            claude_md = claude_dir / "CLAUDE.md"
            claude_md.write_text("# read-only notes\n")
            claude_md.chmod(0o444)
            try:
                result = self.run_import(home, ".claude", ".claude-work")
            finally:
                claude_md.chmod(0o644)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(claude_md.read_text(), "# read-only notes\n")
            self.assertIn("CLAUDE.md", result.stderr)
            other = home / ".claude-work" / "CLAUDE.md"
            self.assertEqual(other.read_text().count(IMPORT_LINE), 1)

    @unittest.skipIf(os.geteuid() == 0, "root ignores file permissions")
    def test_uncreatable_account_dir_skipped(self):
        with tempfile.TemporaryDirectory() as home:
            home = Path(home)
            locked = home / "locked"
            locked.mkdir()
            locked.chmod(0o555)
            try:
                result = self.run_import(home, "locked/.claude", ".claude-work")
            finally:
                locked.chmod(0o755)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((locked / ".claude").exists())
            self.assertIn("locked/.claude", result.stderr)
            other = home / ".claude-work" / "CLAUDE.md"
            self.assertEqual(other.read_text().count(IMPORT_LINE), 1)

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
