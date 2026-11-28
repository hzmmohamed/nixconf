"""Policy tests for broker.py: project resolution, argv and env filtering, the
systemd-run command. The process plumbing is covered by the t3code-broker
NixOS VM test (modules/checks/t3code-vm.nix)."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import broker  # noqa: E402


class BrokerPolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.alpha = root / "projects" / "alpha"
        self.beta = root / "projects" / "beta"
        self.wt = root / "worktrees" / "alpha"
        for d in (self.alpha, self.beta, self.wt / "wt-1", root / "elsewhere"):
            d.mkdir(parents=True)
        self.fake = root / "fake"
        self.fake.write_text("#!/bin/sh\n")
        self.other = root / "other"
        self.other.write_text("#!/bin/sh\n")
        self.registry = {
            "envAllow": ["GLOBAL_OK"],
            "commandPrefix": ["/prefix"],
            "projects": {
                "alpha": {
                    "user": "agent-alpha",
                    "group": "proj-alpha",
                    "home": "/var/lib/agents/alpha",
                    "path": str(self.alpha),
                    "worktreesDir": str(self.wt),
                    "claudeConfigDir": "/var/lib/agents/alpha/claude",
                    "allowedCommands": [str(self.fake)],
                    "envAllow": ["PROJECT_OK"],
                    "env": {"FIXED": "1"},
                    "path_env": "/bin",
                    "properties": ["UMask=0002", "ProtectHome=tmpfs"],
                },
                "beta": {
                    "user": "agent-beta",
                    "group": "proj-beta",
                    "home": "/var/lib/agents/beta",
                    "path": str(self.beta),
                    "worktreesDir": str(root / "worktrees" / "beta"),
                    "claudeConfigDir": None,
                    "allowedCommands": [str(self.fake)],
                    "path_env": "/bin",
                    "properties": [],
                },
            },
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_resolves_project_root_and_worktree(self):
        self.assertEqual(broker.resolve_project(self.registry, str(self.alpha))[0], "alpha")
        self.assertEqual(broker.resolve_project(self.registry, str(self.wt / "wt-1"))[0], "alpha")
        self.assertEqual(broker.resolve_project(self.registry, str(self.beta))[0], "beta")

    def test_refuses_outside_and_prefix_tricks(self):
        with self.assertRaises(broker.Refused):
            broker.resolve_project(self.registry, str(Path(self.tmp.name) / "elsewhere"))
        sibling = Path(f"{self.alpha}-evil")
        sibling.mkdir()
        with self.assertRaises(broker.Refused):  # "alpha-evil" is not under "alpha"
            broker.resolve_project(self.registry, str(sibling))
        with self.assertRaises(broker.Refused):
            broker.resolve_project(self.registry, "relative/path")
        with self.assertRaises(broker.Refused):
            broker.resolve_project(self.registry, str(self.alpha / "missing"))

    def test_symlink_into_project_resolves_to_real_path(self):
        link = Path(self.tmp.name) / "link"
        link.symlink_to(self.alpha)
        self.assertEqual(broker.resolve_project(self.registry, str(link))[0], "alpha")
        out = Path(self.tmp.name) / "out"
        out.symlink_to(Path(self.tmp.name) / "elsewhere")
        (self.alpha / "escape").symlink_to(out)
        with self.assertRaises(broker.Refused):  # a symlink inside the project pointing out
            broker.resolve_project(self.registry, str(self.alpha / "escape"))

    def test_argv_must_start_with_an_allowed_command(self):
        project = self.registry["projects"]["alpha"]
        self.assertEqual(broker.validate_argv(project, [str(self.fake), "a", "b"]), [str(self.fake), "a", "b"])
        for bad in ([], [str(self.other)], ["fake"], ["/bin/sh", "-c", "true"], [str(self.fake), "x\0y"], "fake"):
            with self.assertRaises(broker.Refused, msg=repr(bad)):
                broker.validate_argv(project, bad)

    def test_env_is_allowlisted_and_fixed_values_win(self):
        project = self.registry["projects"]["alpha"]
        env = broker.filter_env(
            self.registry,
            project,
            {
                "TERM": "xterm",
                "SSH_AUTH_SOCK": "/run/user/1000/ssh",
                "GH_TOKEN": "secret",
                "LD_PRELOAD": "/evil.so",
                "GLOBAL_OK": "g",
                "PROJECT_OK": "p",
                "HOME": "/home/t3",
                "PATH": "/home/t3/bin",
                "FIXED": "override",
                "T3CODE_THREAD_ID": "thr",
            },
        )
        self.assertEqual(
            env,
            {
                "TERM": "xterm",
                "GLOBAL_OK": "g",
                "PROJECT_OK": "p",
                "T3CODE_THREAD_ID": "thr",
                "FIXED": "1",
                "HOME": "/var/lib/agents/alpha",
                "PATH": "/bin",
                "CLAUDE_CONFIG_DIR": "/var/lib/agents/alpha/claude",
            },
        )

    def test_env_claude_config_dir_must_match_project(self):
        alpha = self.registry["projects"]["alpha"]
        self.assertEqual(
            broker.filter_env(self.registry, alpha, {"CLAUDE_CONFIG_DIR": "/var/lib/agents/alpha/claude"})["CLAUDE_CONFIG_DIR"],
            "/var/lib/agents/alpha/claude",
        )
        with self.assertRaises(broker.Refused):
            broker.filter_env(self.registry, alpha, {"CLAUDE_CONFIG_DIR": "/var/lib/agents/beta/claude"})
        beta = self.registry["projects"]["beta"]
        with self.assertRaises(broker.Refused):  # beta has no Claude dir: any claim is wrong
            broker.filter_env(self.registry, beta, {"CLAUDE_CONFIG_DIR": "/var/lib/agents/beta/claude"})
        self.assertNotIn("CLAUDE_CONFIG_DIR", broker.filter_env(self.registry, beta, {}))

    def test_env_rejects_malformed_entries(self):
        project = self.registry["projects"]["alpha"]
        for bad in ({"BAD-NAME": "x"}, {"TERM": "a\0b"}, {"TERM": 1}, ["TERM"]):
            with self.assertRaises(broker.Refused, msg=repr(bad)):
                broker.filter_env(self.registry, project, bad)

    def test_build_command(self):
        project = self.registry["projects"]["alpha"]
        unit, cmd = broker.build_command(
            self.registry, "alpha", project, str(self.wt / "wt-1"), [str(self.fake), "--x"], {"HOME": "/h", "A": "1"}, pty=False
        )
        self.assertTrue(unit.startswith("agent-alpha-"))
        self.assertEqual(cmd[0], "systemd-run")
        self.assertIn("--pipe", cmd)
        self.assertNotIn("--pty", cmd)
        for flag in (
            "--wait",
            "--collect",
            f"--unit={unit}",
            "--slice=agents-alpha.slice",
            "--uid=agent-alpha",
            "--gid=proj-alpha",
            f"--working-directory={self.wt / 'wt-1'}",
            "--setenv=A=1",
            "--setenv=HOME=/h",
            "--property=UMask=0002",
            "--property=ProtectHome=tmpfs",
        ):
            self.assertIn(flag, cmd)
        self.assertEqual(cmd[cmd.index("--") + 1 :], ["/prefix", str(self.fake), "--x"])
        _, pty_cmd = broker.build_command(self.registry, "alpha", project, str(self.alpha), [str(self.fake)], {}, pty=True)
        self.assertIn("--pty", pty_cmd)

    def test_registry_round_trips_through_json(self):
        path = Path(self.tmp.name) / "projects.json"
        path.write_text(json.dumps(self.registry))
        os.environ[broker.REGISTRY_ENV] = str(path)
        try:
            self.assertEqual(set(broker.load_registry()["projects"]), {"alpha", "beta"})
        finally:
            del os.environ[broker.REGISTRY_ENV]


if __name__ == "__main__":
    unittest.main()
