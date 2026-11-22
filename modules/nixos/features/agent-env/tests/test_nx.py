#!/usr/bin/env python3
"""Tests for nx.py — run via `python3 -m unittest discover`.

`parse_dry_run` is tested by importing nx.py directly (it has no
module-level side effects). Everything else runs nx.py as a subprocess
against fakes on PATH, the same way test_agent_net.py exercises agent_net.py
— so the test covers argv parsing, exec, exit codes, and stderr wording,
not just the importable helpers.

`nix` itself needs to answer differently depending on the subcommand
(`eval --raw ...`, `build --dry-run ...`, `shell ...`), so unlike the other
fakes (plain FakeBin.add) it is a small Python dispatcher this file writes
itself (fakebin.FakeBin stays generic: one scripted response per binary).
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fakebin import FakeBin  # noqa: E402

NX_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(NX_DIR))
import nx  # noqa: E402

SCRIPT = NX_DIR / "nx.py"


def write_fake_nix(path, calls_file, outpaths=None, pnames=None, dry_run_stderr=""):
    """A fake `nix` that logs every call and answers:
    - `eval --raw nixpkgs#<attr>.outPath` / `.pname` from `outpaths`/`pnames`
      (missing attr -> exit 1, simulating "no such path"/eval failure).
    - `build --dry-run ...` (attr or `--impure --expr ...`) with
      `dry_run_stderr` on stderr, exit 0.
    - anything else (notably `shell ...`) -> logged only, exit 0.
    """
    outpaths = outpaths or {}
    pnames = pnames or {}
    script = f'''#!{sys.executable}
import json, sys

argv = sys.argv[1:]
with open({str(calls_file)!r}, "a") as f:
    f.write(json.dumps(argv) + chr(10))

outpaths = {outpaths!r}
pnames = {pnames!r}

if argv[:2] == ["eval", "--raw"] and len(argv) == 3:
    expr = argv[2]
    if expr.startswith("nixpkgs#") and expr.endswith(".outPath"):
        attr = expr[len("nixpkgs#"):-len(".outPath")]
        table = outpaths
    elif expr.startswith("nixpkgs#") and expr.endswith(".pname"):
        attr = expr[len("nixpkgs#"):-len(".pname")]
        table = pnames
    else:
        sys.exit(1)
    if attr in table:
        sys.stdout.write(table[attr])
        sys.exit(0)
    sys.exit(1)

if argv[:2] == ["build", "--dry-run"]:
    sys.stderr.write({dry_run_stderr!r})
    sys.exit(0)

sys.exit(0)
'''
    path.write_text(script)
    path.chmod(0o755)


class ParseDryRunTests(unittest.TestCase):
    def test_parse_dry_run_units(self):
        mib, _ = nx.parse_dry_run(
            "these 3 paths will be fetched (1.50 MiB download, 6 MiB unpacked):"
        )
        self.assertEqual(mib, 1.5)

        mib, _ = nx.parse_dry_run("(512.0 KiB download")
        self.assertEqual(mib, 0.5)

        mib, _ = nx.parse_dry_run("(2.00 GiB download")
        self.assertEqual(mib, 2048)

        self.assertEqual(nx.parse_dry_run(""), (0.0, []))

        stderr = (
            "these 2 derivations will be built:\n"
            "  /nix/store/abc-foo-1.0.drv\n"
            "  /nix/store/def-python3-3.13-env.drv"
        )
        _, names = nx.parse_dry_run(stderr)
        self.assertEqual(names, ["foo-1.0", "python3-3.13-env"])


class NxCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.fake = FakeBin(self.tmpdir)
        self.nix_calls = self.tmpdir / "nix_calls.jsonl"

    def _nix_call_argvs(self):
        if not self.nix_calls.exists():
            return []
        return [
            json.loads(line)
            for line in self.nix_calls.read_text().splitlines()
            if line
        ]

    def _env(self, **extra):
        # A from-scratch PATH (not fake.env()'s bin_dir:python_dir): the
        # python interpreter dir can contain a real `python3`/`openssl`
        # etc., which would defeat tests that rely on the prog being
        # *absent* from PATH. nx.py itself is still launched by absolute
        # interpreter path, so it never needs python on PATH to start.
        env = {
            "PATH": str(self.fake.bin_dir),
            # A nonexistent dir by default, so a test that doesn't care
            # about the store scan can never accidentally hit the real
            # /nix/store and exec something real.
            "NX_STORE_DIR": str(self.tmpdir / "no-such-store"),
        }
        for k in ("HOME", "LANG", "LC_ALL"):
            if k in os.environ:
                env[k] = os.environ[k]
        env.update(extra)
        return env

    def _store_pkg(self, name):
        """A standalone directory with a fake `bin/<name>` executable,
        used as the pretend nixpkgs outPath / store entry for `name`."""
        pkg_dir = self.tmpdir / f"pkg-{name}-{len(list(self.tmpdir.glob('pkg-*')))}"
        (pkg_dir / "bin").mkdir(parents=True)
        self.fake.add(name, stdout=f"{name} output\n")
        # fake.add writes into fake.bin_dir; copy it into pkg_dir/bin instead.
        src = self.fake.bin_dir / name
        dst = pkg_dir / "bin" / name
        dst.write_text(src.read_text())
        dst.chmod(0o755)
        src.unlink()
        return pkg_dir

    # -- PATH short-circuit --------------------------------------------

    def test_on_path_execs_directly(self):
        self.fake.add("widget", stdout="widget output\n")

        result = self.fake.run(SCRIPT, "widget", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "widget output\n")
        self.assertFalse(self.nix_calls.exists())

    # -- attribute resolution --------------------------------------------

    def test_pinned_present(self):
        # Ruling 2b: `nix eval --raw nixpkgs#openssl.outPath` succeeds, so
        # openssl never goes through nix-locate.
        pkg_dir = self._store_pkg("openssl")
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={"openssl": str(pkg_dir)},
        )

        result = self.fake.run(SCRIPT, "openssl", "version", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "openssl output\n")
        argvs = self._nix_call_argvs()
        self.assertIn(["eval", "--raw", "nixpkgs#openssl.outPath"], argvs)
        self.assertFalse(any(a[:1] == ["build"] for a in argvs))
        self.assertFalse(any(a[:1] == ["shell"] for a in argvs))

    def test_locate_single_toplevel(self):
        # rg -> ripgrep: nix eval on "rg" itself fails, nix-locate returns
        # several dotted/nested outputs that must all be filtered down to
        # the one real top-level attribute.
        pkg_dir = self._store_pkg("rg")
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={"ripgrep": str(pkg_dir)},
        )
        self.fake.add(
            "nix-locate",
            stdout="ripgrep.out\nsomeSet.ripgrep.out\nripgrep.out\n",
        )

        result = self.fake.run(SCRIPT, "rg", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "rg output\n")
        argvs = self._nix_call_argvs()
        self.assertIn(["eval", "--raw", "nixpkgs#ripgrep.outPath"], argvs)

    def test_ambiguous(self):
        self.fake.add("nix-locate", stdout="foo.out\nbar.bin\nbaz.qux.out\n")
        write_fake_nix(self.fake.bin_dir / "nix", self.nix_calls)

        result = self.fake.run(SCRIPT, "baz", env=self._env())
        self.assertEqual(result.returncode, 2)
        self.assertIn("baz is provided by several packages: bar, foo", result.stderr)
        self.assertIn("pick one with -p", result.stderr)
        self.assertNotIn("qux", result.stderr)

    def test_no_package_provides(self):
        self.fake.add("nix-locate", stdout="")
        write_fake_nix(self.fake.bin_dir / "nix", self.nix_calls)

        result = self.fake.run(SCRIPT, "nonexistent", env=self._env())
        self.assertEqual(result.returncode, 2)
        self.assertIn("nx: no package provides nonexistent", result.stderr)

    # -- store scan --------------------------------------------------------

    def test_other_version_from_store(self):
        store_dir = self.tmpdir / "store"
        for name in ("aaa-widget-3.12.11", "bbb-widget-3.13.18"):
            d = store_dir / name / "bin"
            d.mkdir(parents=True)
            (d / "widget").write_text(f"#!{sys.executable}\nimport sys\nsys.stdout.write({name!r} + chr(10))\n")
            (d / "widget").chmod(0o755)

        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            # eval succeeds (attr = prog via ruling 2b) but the outPath it
            # names doesn't actually exist on disk (e.g. GC'd) -> falls
            # through to the store scan.
            outpaths={"widget": str(store_dir / "ghost-widget-0.0.0")},
            pnames={"widget": "widget"},
        )
        self.fake.add("nix-store", exit=0)

        result = self.fake.run(
            SCRIPT, "widget", env=self._env(NX_STORE_DIR=str(store_dir))
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "bbb-widget-3.13.18\n")
        self.assertIn(
            "nx: using bbb-widget-3.13.18 from the store (not the pinned version)",
            result.stderr,
        )
        self.assertFalse(any(a[:1] == ["build"] for a in self._nix_call_argvs()))

    def test_exact_skips_store_scan(self):
        store_dir = self.tmpdir / "store"
        for name in ("aaa-widget-3.12.11", "bbb-widget-3.13.18"):
            d = store_dir / name / "bin"
            d.mkdir(parents=True)
            (d / "widget").write_text(f"#!{sys.executable}\nimport sys\nsys.exit(0)\n")
            (d / "widget").chmod(0o755)

        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={"widget": str(store_dir / "ghost-widget-0.0.0")},
            pnames={"widget": "widget"},
        )

        result = self.fake.run(
            SCRIPT,
            "--exact",
            "widget",
            env=self._env(NX_STORE_DIR=str(store_dir)),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        argvs = self._nix_call_argvs()
        self.assertIn(["build", "--dry-run", "nixpkgs#widget"], argvs)
        self.assertTrue(any(a[:1] == ["shell"] for a in argvs))
        # pname was never even looked up, since the store scan was skipped.
        self.assertFalse(
            any(a == ["eval", "--raw", "nixpkgs#widget.pname"] for a in argvs)
        )

    # -- metered gate --------------------------------------------------------

    def test_metered_refuses_large(self):
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr="these paths will be fetched (312.00 MiB download, 320 MiB unpacked):\n",
        )
        self.fake.add(
            "agent-net",
            stdout=json.dumps(
                {"state": "metered", "connection": "wildflower", "device": "wlo1"}
            )
            + "\n",
        )

        result = self.fake.run(SCRIPT, "-p", "openssl", "openssl", env=self._env())
        self.assertEqual(result.returncode, 3)
        self.assertIn(
            "nx: openssl needs 312 MiB download; on a metered link (wildflower). "
            "Re-run with NX_FORCE=1 to fetch.",
            result.stderr,
        )
        self.assertFalse(any(a[:1] == ["shell"] for a in self._nix_call_argvs()))

    def test_metered_force(self):
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr="these paths will be fetched (312.00 MiB download, 320 MiB unpacked):\n",
        )
        self.fake.add(
            "agent-net",
            stdout=json.dumps(
                {"state": "metered", "connection": "wildflower", "device": "wlo1"}
            )
            + "\n",
        )

        result = self.fake.run(
            SCRIPT,
            "-p",
            "openssl",
            "openssl",
            env=self._env(NX_FORCE="1"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(a[:1] == ["shell"] for a in self._nix_call_argvs()))

    def test_metered_refuses_build_but_not_env(self):
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr=(
                "these derivations will be built:\n"
                "  /nix/store/abc-foo-1.0.drv\n"
            ),
        )
        self.fake.add(
            "agent-net",
            stdout=json.dumps(
                {"state": "metered", "connection": "wildflower", "device": "wlo1"}
            )
            + "\n",
        )

        result = self.fake.run(SCRIPT, "-p", "openssl", "openssl", env=self._env())
        self.assertEqual(result.returncode, 3)
        self.assertIn(
            "nx: openssl needs building foo-1.0; on a metered link (wildflower). "
            "Re-run with NX_FORCE=1 to build.",
            result.stderr,
        )

        # Only an -env derivation (doesn't count) plus a small download:
        # proceeds normally.
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr=(
                "these 2 paths will be fetched (1.00 MiB download, 2 MiB unpacked):\n"
                "these derivations will be built:\n"
                "  /nix/store/def-python3-3.13-env.drv\n"
            ),
        )
        result = self.fake.run(SCRIPT, "-p", "openssl", "openssl", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nx: fetching openssl (1 MiB download)", result.stderr)
        self.assertTrue(any(a[:1] == ["shell"] for a in self._nix_call_argvs()))

    def test_unmetered_large_proceeds(self):
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr="these paths will be fetched (312.00 MiB download, 320 MiB unpacked):\n",
        )
        self.fake.add(
            "agent-net",
            stdout=json.dumps(
                {"state": "unmetered", "connection": "home", "device": "wlo1"}
            )
            + "\n",
        )

        result = self.fake.run(SCRIPT, "-p", "openssl", "openssl", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nx: fetching openssl (312 MiB download)", result.stderr)
        self.assertTrue(any(a[:1] == ["shell"] for a in self._nix_call_argvs()))

    def test_agent_net_missing(self):
        write_fake_nix(
            self.fake.bin_dir / "nix",
            self.nix_calls,
            outpaths={},
            pnames={"openssl": "openssl"},
            dry_run_stderr="these paths will be fetched (312.00 MiB download, 320 MiB unpacked):\n",
        )
        # No fake agent-net on PATH at all.

        result = self.fake.run(SCRIPT, "-p", "openssl", "openssl", env=self._env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nx: fetching openssl (312 MiB download)", result.stderr)
        self.assertTrue(any(a[:1] == ["shell"] for a in self._nix_call_argvs()))

    # -- --py mode --------------------------------------------------------

    def test_py_builds_expression(self):
        write_fake_nix(self.fake.bin_dir / "nix", self.nix_calls, dry_run_stderr="")

        result = self.fake.run(
            SCRIPT, "--py", "requests", "rich", "--", "-c", "print(1)", env=self._env()
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        argvs = self._nix_call_argvs()
        shell_calls = [a for a in argvs if a[:1] == ["shell"]]
        self.assertEqual(len(shell_calls), 1)
        argv = shell_calls[0]
        self.assertIn("--impure", argv)
        self.assertIn("--expr", argv)
        expr = argv[argv.index("--expr") + 1]
        self.assertIn("[requests rich]", expr)
        self.assertEqual(argv[-4:], ["-c", "python3", "-c", "print(1)"])


if __name__ == "__main__":
    unittest.main()
