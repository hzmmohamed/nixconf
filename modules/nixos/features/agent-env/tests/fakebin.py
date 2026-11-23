#!/usr/bin/env python3
"""Test helper: fake executables for agent-net's external tools (`ip`, `nmcli`).

Each fake is a tiny Python script with a `#!<python>` shebang (never
`#!/usr/bin/env python3` — the nix build sandbox has no /usr/bin/env). It
prints canned output/exit code and appends its argv to a per-tool JSONL log
so tests can assert on exactly how it was invoked.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


class FakeBin:
    def __init__(self, tmpdir):
        self.dir = Path(tmpdir)
        self.bin_dir = self.dir / "bin"
        self.calls_dir = self.dir / "calls"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.calls_dir.mkdir(parents=True, exist_ok=True)

    def add(self, name, stdout="", stderr="", exit=0, sleep=0):
        calls_file = self.calls_dir / f"{name}.jsonl"
        script = self.bin_dir / name
        lines = [
            f"#!{sys.executable}",
            "import json, sys",
            f"with open({str(calls_file)!r}, 'a') as f:",
            "    f.write(json.dumps(sys.argv) + chr(10))",
        ]
        if sleep:
            # For hook-robustness tests: a fake that outlives agent-net's own
            # subprocess timeout (1.5s), so the hook must not just wait on it.
            lines.append("import time")
            lines.append(f"time.sleep({sleep!r})")
        if stdout:
            lines.append(f"sys.stdout.write({stdout!r})")
        if stderr:
            lines.append(f"sys.stderr.write({stderr!r})")
        lines.append(f"sys.exit({exit!r})")
        script.write_text("\n".join(lines) + "\n")
        script.chmod(0o755)
        return script

    def calls(self, name):
        calls_file = self.calls_dir / f"{name}.jsonl"
        if not calls_file.exists():
            return []
        return [
            json.loads(line) for line in calls_file.read_text().splitlines() if line
        ]

    def env(self, **extra):
        env = dict(os.environ)
        env["PATH"] = f"{self.bin_dir}:{self._sys_path()}"
        env.update(extra)
        return env

    def _sys_path(self) -> str:
        # Hermetic: python3 alone (a symlink, not its whole profile dir,
        # which may hold the real agent-net/nx/direnv once deployed) plus the
        # coreutils store dir for the shell fakes (sleep, cat, ...).
        py_dir = self.dir / "py"
        if not py_dir.exists():
            py_dir.mkdir()
            (py_dir / "python3").symlink_to(sys.executable)
        dirs = [str(py_dir)]
        sleep = shutil.which("sleep")
        if sleep:
            dirs.append(str(Path(sleep).resolve().parent))
        return ":".join(dirs)

    def run(self, script, *args, stdin="", env=None, cwd=None):
        return subprocess.run(
            [sys.executable, str(script), *args],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=10,
            env=env if env is not None else self.env(),
            cwd=cwd,
        )
