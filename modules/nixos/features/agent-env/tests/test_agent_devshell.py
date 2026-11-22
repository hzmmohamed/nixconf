#!/usr/bin/env python3
"""Tests for agent_devshell.py — run via `python3 -m unittest discover`.

`direnv` and `git` need to answer differently depending on the directory
they're invoked against (`status --json`/`export json` per-root, `rev-parse`
per-root), so unlike the plain FakeBin.add fakes (`systemd-run`, `agent-net`)
they are small Python dispatchers this file writes itself — the same
approach test_nx.py uses for its `nix` fake. The target BINARY is also a
small dispatcher: it prints {"AGENT_DEVSHELL": ..., "argv": [...], ...} as
JSON so tests can assert on exactly what ran, what it saw, and (for the
`loaded` path) what `direnv export json` handed it.

`WorktreeMainRootRealGitTests` exercises `_worktree_main_root` against a
real temporary git repo + `git worktree add` (skipped if `git` isn't on
PATH) rather than the `git` dispatcher fake, since the bug it guards
against (the main root resolving wrong for a worktree *subdirectory*) is
exactly the kind of thing a hand-rolled fake can accidentally "fix" by
matching the implementation's own assumptions instead of real git's.

Real temp dirs throughout; `HOME` is set to a temp parent that is never one
of the project roots used in a test, so `.envrc` lookups can't wander into
it by accident.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from fakebin import FakeBin  # noqa: E402

AGENT_ENV_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(AGENT_ENV_DIR))
import agent_devshell  # noqa: E402

SCRIPT = AGENT_ENV_DIR / "agent_devshell.py"


def write_fake_direnv(path, calls_file, status_map=None, export_map=None):
    """A fake `direnv` dispatching on argv:
    - `status --json` (cwd-sensitive): looks up `status_map[cwd]`; missing
      key -> exit 1 (direnv failed / no .envrc there).
    - `allow <path>`: logs and exits 0.
    - `export json` (cwd-sensitive): looks up `export_map[cwd]`, a dict
      that may have:
        "json": {var: value} -> printed as the export JSON (default {}).
        "fail": True         -> exit 1, nothing on stdout.
        "bad_json": True     -> exit 0, unparseable stdout.
        "sleep": seconds     -> sleep before answering (timeout tests).
        "spawn_pidfile": path -> first start a long-running grandchild
                                (like direnv's bash + `nix print-dev-env`),
                                writing its pid to `path`.
      Missing cwd -> prints "{}" (no changes), exit 0.
    - `exec <root> BINARY ARGS...`: logs, then execs BINARY ARGS directly
      (inheriting this process's environment, same as the real `direnv
      exec`), mirroring "shift 2; exec \"$@\"" -- only still used for the
      warm-up probe (`direnv exec <root> true`).
    """
    status_map = status_map or {}
    export_map = export_map or {}
    script = f'''#!{sys.executable}
import json, os, sys, time

argv = sys.argv[1:]
with open({str(calls_file)!r}, "a") as f:
    f.write(json.dumps({{"argv": argv, "cwd": os.getcwd()}}) + chr(10))

status_map = {status_map!r}
export_map = {export_map!r}

if argv[:2] == ["status", "--json"]:
    cwd = os.getcwd()
    if cwd in status_map:
        sys.stdout.write(json.dumps(status_map[cwd]))
        sys.exit(0)
    sys.exit(1)

if argv[:1] == ["allow"]:
    sys.exit(0)

if argv[:2] == ["export", "json"]:
    cwd = os.getcwd()
    spec = export_map.get(cwd) or {{}}
    if spec.get("spawn_pidfile"):
        import subprocess
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        with open(spec["spawn_pidfile"], "w") as f:
            f.write(str(child.pid))
    if spec.get("sleep"):
        time.sleep(spec["sleep"])
    if spec.get("fail"):
        sys.stderr.write("direnv: export failed\\n")
        sys.exit(1)
    if spec.get("bad_json"):
        sys.stdout.write("not json")
        sys.exit(0)
    sys.stdout.write(json.dumps(spec.get("json", {{}})))
    sys.exit(0)

if argv[:1] == ["exec"]:
    rest = argv[2:]
    os.execvp(rest[0], rest)

sys.exit(1)
'''
    path.write_text(script)
    path.chmod(0o755)


def write_fake_git(path, common_dirs, worktree_lists=None):
    """A fake `git` answering `-C <root> rev-parse --path-format=absolute
    --show-toplevel --git-common-dir` from `common_dirs[root] = (toplevel,
    common_dir)` (both already absolute, as real git prints them with
    `--path-format=absolute`). Any root not in the table behaves like a
    plain (non-worktree) repo: toplevel = root, common-dir = "<root>/.git".

    It also answers `-C <main> worktree list --porcelain`: by default every
    `common_dirs` toplevel whose common dir is `<main>/.git` is listed as a
    registered worktree of `<main>` (i.e. a genuine `git worktree add`);
    `worktree_lists[main] = [paths]` overrides that per main checkout."""
    if worktree_lists is None:
        worktree_lists = {}
        for toplevel, common_dir in common_dirs.values():
            main = str(Path(common_dir).parent)
            worktree_lists.setdefault(main, []).append(toplevel)
    script = f'''#!{sys.executable}
import sys

argv = sys.argv[1:]
common_dirs = {common_dirs!r}
worktree_lists = {worktree_lists!r}

if argv[:1] == ["-C"] and argv[2:] == ["worktree", "list", "--porcelain"]:
    main = argv[1]
    out = "worktree " + main + "\\nHEAD 0000\\nbranch refs/heads/main\\n"
    for wt in worktree_lists.get(main, []):
        out += "\\nworktree " + wt + "\\nHEAD 0000\\nbranch refs/heads/wt\\n"
    sys.stdout.write(out)
    sys.exit(0)

expected_tail = ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]
if argv[:1] == ["-C"] and argv[2:] == expected_tail:
    root = argv[1]
    if root in common_dirs:
        toplevel, common_dir = common_dirs[root]
    else:
        toplevel, common_dir = root, root + "/.git"
    sys.stdout.write(toplevel + "\\n" + common_dir + "\\n")
    sys.exit(0)

sys.exit(1)
'''
    path.write_text(script)
    path.chmod(0o755)


def write_fake_binary(path):
    """BINARY: prints {"AGENT_DEVSHELL": ..., "argv": [...], "DEVENV_ROOT":
    ...} as JSON -- the last field lets tests confirm a `direnv export
    json` value actually reached the binary's environment."""
    script = f'''#!{sys.executable}
import json, os, sys

print(json.dumps({{
    "AGENT_DEVSHELL": os.environ.get("AGENT_DEVSHELL"),
    "argv": sys.argv[1:],
    "DEVENV_ROOT": os.environ.get("DEVENV_ROOT"),
}}))
'''
    path.write_text(script)
    path.chmod(0o755)


def allowed_status(path):
    return {"config": {}, "state": {"foundRC": {"allowed": 0, "path": path}, "loadedRC": None}}


def not_allowed_status(path):
    return {"config": {}, "state": {"foundRC": {"allowed": 1, "path": path}, "loadedRC": None}}


def denied_status(path):
    """direnv's AllowStatus 2: the user explicitly ran `direnv deny`."""
    return {"config": {}, "state": {"foundRC": {"allowed": 2, "path": path}, "loadedRC": None}}


class AgentDevshellTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.home = self.tmpdir / "home"
        self.home.mkdir()
        self.fake = FakeBin(self.tmpdir / "fakebin")
        self.calls_dir = self.tmpdir / "fakebin" / "calls"

    def _mk_project(self, name="project"):
        root = self.tmpdir / name
        root.mkdir(parents=True, exist_ok=True)
        (root / ".envrc").write_text("use flake\n")
        (root / "flake.nix").write_text("{}\n")
        return root

    def _env(self, **extra):
        return self.fake.env(HOME=str(self.home), **extra)

    def _cache(self, root, newer_than="flake.nix", stale=False):
        """Create a .direnv/flake-profile-<hex>(.rc) pair that resolves to
        an existing target. `.rc` is touched after (or, if stale, before)
        `newer_than`."""
        direnv_dir = root / ".direnv"
        direnv_dir.mkdir(exist_ok=True)
        target = self.tmpdir / "store-target"
        target.mkdir(exist_ok=True)
        link = direnv_dir / "flake-profile-aaaa"
        if not link.exists():
            link.symlink_to(target)
        rc = direnv_dir / "flake-profile-aaaa.rc"
        rc.write_text("# cached\n")
        ref = root / newer_than
        ref_mtime = ref.stat().st_mtime
        rc_mtime = (ref_mtime - 10) if stale else (ref_mtime + 10)
        os.utime(rc, (rc_mtime, rc_mtime))

    def test_no_envrc_none(self):
        root = self.tmpdir / "bare"
        root.mkdir()
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(
            SCRIPT, str(binpath), "arg1", env=self._env(), cwd=str(root)
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "none")
        self.assertEqual(out["argv"], ["arg1"])

    def test_envrc_in_home_ignored(self):
        (self.home / ".envrc").write_text("use flake\n")
        root = self.tmpdir / "bare2"
        root.mkdir()
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "none")

    def test_not_allowed(self):
        root = self._mk_project()
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): not_allowed_status(str(root / ".envrc"))},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-allowed")
        direnv_calls = self.fake.calls("direnv")
        self.assertFalse(any(c["argv"][:1] == ["exec"] for c in direnv_calls))

    def test_loaded_when_cached(self):
        root = self._mk_project()
        self._cache(root)
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
            export_map={str(root): {"json": {"DEVENV_ROOT": str(root)}}},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), "x", env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "loaded")
        self.assertEqual(out["argv"], ["x"])
        self.assertEqual(out["DEVENV_ROOT"], str(root))
        direnv_calls = self.fake.calls("direnv")
        export_calls = [c for c in direnv_calls if c["argv"][:2] == ["export", "json"]]
        self.assertEqual(len(export_calls), 1)
        self.assertEqual(export_calls[0]["cwd"], str(root))
        # loaded no longer goes through `direnv exec` at all.
        self.assertFalse(any(c["argv"][:1] == ["exec"] for c in direnv_calls))

    def test_stale_profile_not_built(self):
        root = self._mk_project()
        self._cache(root, stale=True)
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
        )
        self.fake.add("agent-net", stdout=json.dumps({"state": "unmetered"}))
        self.fake.add("systemd-run")
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")

    def test_nested_cwd_finds_root(self):
        root = self._mk_project()
        self._cache(root)
        nested = root / "app" / "src"
        nested.mkdir(parents=True)
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
            export_map={str(root): {"json": {"DEVENV_ROOT": str(root)}}},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(nested))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "loaded")
        self.assertEqual(out["DEVENV_ROOT"], str(root))
        direnv_calls = self.fake.calls("direnv")
        status_calls = [c for c in direnv_calls if c["argv"][:2] == ["status", "--json"]]
        self.assertEqual(status_calls[0]["cwd"], str(root))
        export_calls = [c for c in direnv_calls if c["argv"][:2] == ["export", "json"]]
        self.assertEqual(export_calls[0]["cwd"], str(root))

    def test_argv_passthrough(self):
        args = ['--flag="a b"', "it's", "x=y", ""]
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        # none
        root_none = self.tmpdir / "none-root"
        root_none.mkdir()
        result = self.fake.run(SCRIPT, str(binpath), *args, env=self._env(), cwd=str(root_none))
        self.assertEqual(json.loads(result.stdout)["argv"], args)

        # not-built
        root = self._mk_project("passthrough")
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
        )
        self.fake.add("agent-net", stdout=json.dumps({"state": "metered"}))
        result = self.fake.run(SCRIPT, str(binpath), *args, env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        self.assertEqual(out["argv"], args)

        # loaded
        self._cache(root)
        result = self.fake.run(SCRIPT, str(binpath), *args, env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "loaded")
        self.assertEqual(out["argv"], args)

    def test_warmup_only_unmetered(self):
        root = self._mk_project()
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
        )
        self.fake.add("systemd-run")
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        self.fake.add("agent-net", stdout=json.dumps({"state": "metered"}))
        self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        self.assertEqual(self.fake.calls("systemd-run"), [])

        (self.calls_dir / "systemd-run.jsonl").unlink(missing_ok=True)
        self.fake.add("agent-net", stdout=json.dumps({"state": "unmetered"}))
        self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        calls = self.fake.calls("systemd-run")
        self.assertEqual(len(calls), 1)
        self.assertIn("agent-devshell-warm-", " ".join(calls[0]))

    def test_agent_net_missing(self):
        root = self._mk_project()
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
        )
        self.fake.add("systemd-run")
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)
        # no agent-net on PATH at all

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        self.assertEqual(len(self.fake.calls("systemd-run")), 1)

    def test_error_still_execs(self):
        root = self._mk_project()
        direnv_path = self.fake.bin_dir / "direnv"
        direnv_path.write_text(f"#!{sys.executable}\nimport sys\nsys.stdout.write('not json')\nsys.exit(1)\n")
        direnv_path.chmod(0o755)
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), "y", env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "error")
        self.assertEqual(out["argv"], ["y"])

    def test_export_failure_still_execs(self):
        """Allowed and cached, but `direnv export json` itself fails (exit
        1, no JSON): AGENT_DEVSHELL=error, binary still runs with its
        argv intact."""
        root = self._mk_project()
        self._cache(root)
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
            export_map={str(root): {"fail": True}},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), "z", env=self._env(), cwd=str(root))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "error")
        self.assertEqual(out["argv"], ["z"])

    def test_export_timeout_not_built(self):
        """Allowed and cached, but `direnv export json` hangs past the
        (test-shortened) timeout: AGENT_DEVSHELL=not-built, binary still
        runs, and no warm-up is fired for this case."""
        root = self._mk_project()
        self._cache(root)
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
            export_map={str(root): {"sleep": 2}},
        )
        self.fake.add("systemd-run")
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(
            SCRIPT,
            str(binpath),
            env=self._env(AGENT_DEVSHELL_EXPORT_TIMEOUT="0.2"),
            cwd=str(root),
        )
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        self.assertEqual(self.fake.calls("systemd-run"), [])

    def test_export_timeout_kills_process_group(self):
        """I4: a timed-out `direnv export json` must not leave its children
        (bash + `nix print-dev-env`, i.e. a background build/download)
        running: the whole process group is killed, not just direnv."""
        root = self._mk_project()
        self._cache(root)
        pidfile = self.tmpdir / "grandchild.pid"
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
            export_map={str(root): {"sleep": 30, "spawn_pidfile": str(pidfile)}},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(
            SCRIPT,
            str(binpath),
            env=self._env(AGENT_DEVSHELL_EXPORT_TIMEOUT="0.5"),
            cwd=str(root),
        )
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        pid = int(pidfile.read_text())
        self.addCleanup(_kill_quietly, pid)
        self.assertTrue(_wait_gone(pid, 3.0), f"grandchild {pid} still running")

    def test_warmup_passes_direnv_config(self):
        """C1: the warm-up runs under the user manager, which doesn't
        inherit our environment; DIRENV_CONFIG (set by the wrapper so
        nix-direnv's use_flake is used) must be passed explicitly."""
        root = self._mk_project()
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={str(root): allowed_status(str(root / ".envrc"))},
        )
        self.fake.add("systemd-run")
        self.fake.add("agent-net", stdout=json.dumps({"state": "unmetered"}))
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        self.fake.run(
            SCRIPT, str(binpath), env=self._env(DIRENV_CONFIG="/etc/direnv"), cwd=str(root)
        )
        calls = self.fake.calls("systemd-run")
        self.assertEqual(len(calls), 1)
        argv = calls[0]
        self.assertIn("--setenv=DIRENV_CONFIG=/etc/direnv", argv)
        self.assertLess(argv.index("--setenv=DIRENV_CONFIG=/etc/direnv"), argv.index("--"))

    def test_worktree_denied_not_auto_allowed(self):
        """C3: a worktree whose .envrc the user explicitly denied (direnv
        allowed=2) is never auto-allowed, even if main is allowed and the
        .envrc is byte-identical."""
        main = self._mk_project("main-denied")
        wt = self.tmpdir / "wt-denied"
        wt.mkdir()
        (wt / ".envrc").write_text((main / ".envrc").read_text())

        write_fake_git(
            self.fake.bin_dir / "git",
            common_dirs={str(wt): (str(wt), str(main / ".git"))},
        )
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={
                str(wt): denied_status(str(wt / ".envrc")),
                str(main): allowed_status(str(main / ".envrc")),
            },
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(wt))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-allowed")
        allow_calls = [c for c in self.fake.calls("direnv") if c["argv"][:1] == ["allow"]]
        self.assertEqual(allow_calls, [])

    def test_worktree_auto_allow(self):
        main = self._mk_project("main")
        wt = self.tmpdir / "wt"
        wt.mkdir()
        (wt / ".envrc").write_text((main / ".envrc").read_text())

        write_fake_git(
            self.fake.bin_dir / "git",
            common_dirs={str(wt): (str(wt), str(main / ".git"))},
        )
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={
                str(wt): not_allowed_status(str(wt / ".envrc")),
                str(main): allowed_status(str(main / ".envrc")),
            },
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(wt))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        direnv_calls = self.fake.calls("direnv")
        allow_calls = [c for c in direnv_calls if c["argv"][:1] == ["allow"]]
        self.assertEqual(len(allow_calls), 1)
        self.assertEqual(allow_calls[0]["argv"][1], str(wt))

    def test_worktree_auto_allow_differing_envrc_not_allowed(self):
        main = self._mk_project("main2")
        wt = self.tmpdir / "wt2"
        wt.mkdir()
        (wt / ".envrc").write_text("use flake .#other\n")

        write_fake_git(
            self.fake.bin_dir / "git",
            common_dirs={str(wt): (str(wt), str(main / ".git"))},
        )
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={
                str(wt): not_allowed_status(str(wt / ".envrc")),
                str(main): allowed_status(str(main / ".envrc")),
            },
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(wt))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-allowed")
        direnv_calls = self.fake.calls("direnv")
        allow_calls = [c for c in direnv_calls if c["argv"][:1] == ["allow"]]
        self.assertEqual(allow_calls, [])

    def test_worktree_cached_via_main(self):
        main = self._mk_project("main3")
        self._cache(main)
        wt = self.tmpdir / "wt3"
        wt.mkdir()
        (wt / ".envrc").write_text((main / ".envrc").read_text())
        (wt / "flake.nix").write_text((main / "flake.nix").read_text())

        write_fake_git(
            self.fake.bin_dir / "git",
            common_dirs={str(wt): (str(wt), str(main / ".git"))},
        )
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={
                str(wt): allowed_status(str(wt / ".envrc")),
                str(main): allowed_status(str(main / ".envrc")),
            },
            export_map={str(wt): {"json": {"DEVENV_ROOT": str(wt)}}},
        )
        binpath = self.fake.bin_dir / "target-bin"
        write_fake_binary(binpath)

        result = self.fake.run(SCRIPT, str(binpath), env=self._env(), cwd=str(wt))
        out = json.loads(result.stdout)
        self.assertEqual(out["AGENT_DEVSHELL"], "loaded")
        self.assertEqual(out["DEVENV_ROOT"], str(wt))
        direnv_calls = self.fake.calls("direnv")
        export_calls = [c for c in direnv_calls if c["argv"][:2] == ["export", "json"]]
        self.assertEqual(len(export_calls), 1)
        self.assertEqual(export_calls[0]["cwd"], str(wt))
        # The cache check only consults the main checkout's .direnv; it
        # must not shell out to `direnv exec`/`export` there too.
        self.assertFalse(any(c["cwd"] == str(main) and c["argv"][:1] != ["status"] for c in direnv_calls))


def _pid_alive(pid):
    """True if `pid` exists and isn't a zombie (a zombie has already been
    killed, it just hasn't been reaped by whoever adopted it)."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            state = f.read().rsplit(")", 1)[1].split()[0]
        return state != "Z"
    except OSError:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True


def _wait_gone(pid, timeout):
    import time

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _pid_alive(pid):
            return True
        time.sleep(0.05)
    return not _pid_alive(pid)


def _kill_quietly(pid):
    try:
        os.kill(pid, 9)
    except OSError:
        pass


@unittest.skipUnless(shutil.which("git"), "git not available on PATH")
class WorktreeAutoAllowRealGitTests(unittest.TestCase):
    """C3: the worktree auto-allow against real git. Only a worktree that
    the main checkout itself has registered (`git worktree list`) counts;
    a directory with a hand-written `.git` file pointing at the main
    checkout's git dir (which makes `rev-parse` report it as a linked
    worktree) must not be auto-allowed. direnv stays a fake."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.home = self.tmpdir / "home"
        self.home.mkdir()
        self.fake = FakeBin(self.tmpdir / "fakebin")
        self.calls_dir = self.tmpdir / "fakebin" / "calls"
        self.main = self.tmpdir / "main"
        self.main.mkdir()
        self._git("init", "-q", str(self.main))
        self._git("-C", str(self.main), "config", "user.email", "agent-env-test@example.com")
        self._git("-C", str(self.main), "config", "user.name", "agent-env-test")
        (self.main / ".envrc").write_text("use flake\n")
        (self.main / "flake.nix").write_text("{}\n")
        self._git("-C", str(self.main), "add", "-A")
        self._git("-C", str(self.main), "commit", "-q", "-m", "init")
        write_fake_binary(self.fake.bin_dir / "target-bin")
        # metered: no warm-up is attempted (and no systemd-run needed).
        self.fake.add("agent-net", stdout=json.dumps({"state": "metered"}))

    def _git(self, *args):
        result = subprocess.run(["git", *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def _env(self):
        env = self.fake.env(HOME=str(self.home))
        env["PATH"] += ":" + str(Path(shutil.which("git")).parent)
        return env

    def _run_in(self, root):
        write_fake_direnv(
            self.fake.bin_dir / "direnv",
            self.calls_dir / "direnv.jsonl",
            status_map={
                str(root): not_allowed_status(str(root / ".envrc")),
                str(self.main): allowed_status(str(self.main / ".envrc")),
            },
        )
        result = self.fake.run(
            SCRIPT, str(self.fake.bin_dir / "target-bin"), env=self._env(), cwd=str(root)
        )
        allow_calls = [c for c in self.fake.calls("direnv") if c["argv"][:1] == ["allow"]]
        return json.loads(result.stdout), allow_calls

    def test_real_worktree_auto_allowed(self):
        wt = self.tmpdir / "wt"
        self._git("-C", str(self.main), "worktree", "add", "-q", str(wt), "-b", "wtbranch")
        out, allow_calls = self._run_in(wt)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-built")
        self.assertEqual([c["argv"] for c in allow_calls], [["allow", str(wt)]])

    def test_forged_git_file_not_allowed(self):
        forged = self.tmpdir / "forged"
        forged.mkdir()
        (forged / ".git").write_text(f"gitdir: {self.main / '.git'}\n")
        (forged / ".envrc").write_bytes((self.main / ".envrc").read_bytes())
        out, allow_calls = self._run_in(forged)
        self.assertEqual(out["AGENT_DEVSHELL"], "not-allowed")
        self.assertEqual(allow_calls, [])

    def test_forged_git_file_not_cached_via_main(self):
        """The cache shortcut (main's .direnv) is a worktree privilege
        too: a forged directory never borrows it."""
        forged = self.tmpdir / "forged2"
        forged.mkdir()
        (forged / ".git").write_text(f"gitdir: {self.main / '.git'}\n")
        self.assertIsNone(agent_devshell._worktree_main_root(forged))


@unittest.skipUnless(shutil.which("git"), "git not available on PATH")
class WorktreeMainRootRealGitTests(unittest.TestCase):
    """`_worktree_main_root` against a real git repo + `git worktree add`,
    covering the bug this fix round addresses: `--git-common-dir` (without
    `--path-format=absolute`) is relative to the `-C` directory, not the
    toplevel, so a worktree *subdirectory* used to resolve to the wrong
    main-checkout path (or a nonexistent one)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmpdir = Path(self._tmp.name)
        self.main = self.tmpdir / "main"
        self.main.mkdir()
        self._git("init", "-q", str(self.main))
        self._git("-C", str(self.main), "config", "user.email", "agent-env-test@example.com")
        self._git("-C", str(self.main), "config", "user.name", "agent-env-test")
        (self.main / "app").mkdir()
        (self.main / "app" / ".keep").write_text("")
        self._git("-C", str(self.main), "add", "-A")
        self._git("-C", str(self.main), "commit", "-q", "-m", "init")

    def _git(self, *args):
        result = subprocess.run(["git", *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_main_checkout_subdir_is_not_a_worktree(self):
        main_root = agent_devshell._worktree_main_root(self.main / "app")
        self.assertIsNone(main_root)

    def test_worktree_subdir_resolves_to_main_subdir(self):
        wt = self.tmpdir / "wt"
        self._git("-C", str(self.main), "worktree", "add", "-q", str(wt), "-b", "wtbranch")
        main_root = agent_devshell._worktree_main_root(wt / "app")
        self.assertIsNotNone(main_root)
        self.assertEqual(main_root.resolve(), (self.main / "app").resolve())

    def test_worktree_subdir_missing_in_main_is_none(self):
        wt = self.tmpdir / "wt2"
        self._git("-C", str(self.main), "worktree", "add", "-q", str(wt), "-b", "wtbranch2")
        (wt / "extra").mkdir()  # exists in the worktree, not in main
        main_root = agent_devshell._worktree_main_root(wt / "extra")
        self.assertIsNone(main_root)


if __name__ == "__main__":
    unittest.main()
