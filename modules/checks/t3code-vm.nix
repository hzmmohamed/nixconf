# VM tests for services.t3code and services.agent-broker
# (docs/plans/2026-11-28-t3-separate-user-spike.md §2.3 and §3.5). Both run
# the real `t3 serve` as `t3` with a fake provider pinned by policy.
#
#   nix build --no-link -L .#checks.x86_64-linux.t3code-user
#   nix build --no-link -L .#checks.x86_64-linux.t3code-broker
#
# t3code-user: stage 1. The server runs as `t3`, listens on loopback only,
# keeps its state 0700, an operator drives it through `t3ctl` and a thread
# started from the CLI reaches the provider as `t3` in a T3-made worktree.
#
# t3code-broker: stage 2. The same server, the provider behind the broker:
# runs as `agent-alpha` in its sandbox (identity, env scrub, filesystem
# fences, group-shared worktree + git both ways, exit codes, lifetime,
# caps, network, refusals, PTY terminal), then end to end from a T3 thread.
{
  inputs,
  self,
  ...
}: {
  perSystem = {pkgs, ...}: let
    t3code = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.t3code;

    # Stands in for `claude`: records who ran it, then does what $1 says.
    fakeProvider = pkgs.writeShellScript "fake-claude" ''
      # One record per run: T3 also probes the binary at startup (in its state dir).
      record() {
        mkdir -p "$HOME/fake-runs"
        { echo "uid=$(id -u)"; echo "user=$(id -un)"; echo "home=$HOME"; echo "pwd=$PWD"; env | sort; } > "$HOME/fake-runs/$(date +%s%N).log"
      }
      p() { n=$1; shift; if "$@" >/dev/null 2>&1; then echo "$n=ok"; else echo "$n=fail"; fi; }
      case "''${1:-}" in
        --version) echo "fake-claude 0.0.0" ;;
        record) record; echo recorded ;;
        exit) exit "$2" ;;
        cat) exec cat ;;
        sleep) exec sleep "$2" ;;
        probe)
          record
          p write-worktree sh -c 'echo x > ./agent-file && [ "$(stat -c %G ./agent-file)" = proj-alpha ] && stat -c %A ./agent-file | grep -q "^-rw-rw"'
          p git-commit git commit --allow-empty -q -m "agent commit"
          p read-attachment cat /var/lib/t3code/.t3/userdata/attachments/x.txt
          p write-attachment sh -c 'echo y > /var/lib/t3code/.t3/userdata/attachments/y'
          p read-db ls /var/lib/t3code/.t3/userdata/statev2.sqlite
          p read-secrets ls /var/lib/t3code/.t3/userdata/secrets
          p read-beta ls /var/lib/t3code/projects/beta
          p read-op-home ls /home/op
          p write-etc touch /etc/agent-was-here
          p write-store touch /nix/store/agent-was-here
          p read-nix-socket test -w /nix/var/nix/daemon-socket/socket
          p loopback curl -s -o /dev/null --max-time 3 http://127.0.0.1:3773/
          p outside-net curl -s -o /dev/null --max-time 3 http://10.0.2.2:80/
          slice=$(cut -d: -f3 /proc/self/cgroup | sed 's|/[^/]*$||')
          echo "cgroup=$(cut -d: -f3 /proc/self/cgroup)"
          echo "memory-max=$(cat /sys/fs/cgroup$slice/memory.max 2>/dev/null || echo unreadable)"
          echo "ssh-auth-sock=''${SSH_AUTH_SOCK:-unset}"
          echo "gh-token=''${GH_TOKEN:-unset}"
          echo "config-dir=''${CLAUDE_CONFIG_DIR:-unset}"
          echo "thread-id=''${T3CODE_THREAD_ID:-unset}"
          ;;
        *) record; echo "fake-claude: not a real provider ($*)" >&2; exit 1 ;;
      esac
    '';

    policy = binaryPath: {
      schemaVersion = 1;
      organization = "t3code-vm test";
      settings = {
        enableProviderUpdateChecks = {
          value = false;
          locked = false;
        };
        automaticGitFetchInterval = {
          value = 0;
          locked = false;
        };
      };
      limits = {
        connect = false;
        webhookTasks = false;
        telemetry = false;
        browserCookieImport = false;
        updates = {
          mode = "off";
          allowNightly = false;
        };
        providers = {
          allowedDrivers = ["claudeAgent"];
          instances.claudeAgent = {
            locked = true;
            inherit binaryPath;
          };
        };
      };
    };

    common = {
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      environment.systemPackages = [pkgs.curl pkgs.jq pkgs.git pkgs.util-linux pkgs.acl];
      users.users.op = {
        isNormalUser = true;
        # Something only the owner may read.
        initialPassword = "op";
      };
      services.t3code = {
        enable = true;
        package = t3code;
        operators = ["op"];
        operatorsNoPass = true;
        path = [pkgs.systemd];
        settings.providerInstances.claudeAgent = {
          driver = "claudeAgent";
          enabled = true;
        };
      };
      # A repo the test's threads can use: owned by t3 like a bootstrap clone.
      systemd.services.t3code-test-repo = {
        wantedBy = ["multi-user.target"];
        before = ["t3code.service"];
        after = ["systemd-tmpfiles-setup.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "t3";
          UMask = "0002";
        };
        path = [pkgs.git pkgs.coreutils];
        script = ''
          for p in alpha beta; do
            d=/var/lib/t3code/projects/$p
            mkdir -p "$d"
            [ -d "$d/.git" ] && continue
            git -C "$d" init -q -b main
            git -C "$d" config user.name t3
            git -C "$d" config user.email t3@localhost
            git -C "$d" config core.sharedRepository group
            echo "# $p" > "$d/README.md"
            git -C "$d" add README.md
            git -C "$d" commit -q -m init
          done
        '';
      };
    };

    # Python helpers shared by both scripts.
    pyCommon = ''
      import json

      def as_user(user, cmd):
          return f"runuser -u {user} -- sh -c {json.dumps(cmd)}"

      def kv(text):
          out = {}
          for line in text.splitlines():
              k, _, v = line.partition("=")
              out.setdefault(k, v)
          return out

      def latest_run(home, user):
          return machine.succeed(as_user(user, f"cat \"$(ls -t {home}/fake-runs/*.log | head -1)\""))

      def wait_thread_run(home, user, timeout=120):
          """The run T3 started for a thread: the one whose cwd is a worktree."""
          f = machine.wait_until_succeeds(
              as_user(user, f"grep -l '^pwd=/var/lib/t3code/.t3/worktrees/' {home}/fake-runs/*.log"), timeout=timeout
          ).split()[0]
          return machine.succeed(as_user(user, f"cat {f}"))

      def server_up():
          machine.wait_for_unit("t3code.service")
          machine.wait_for_open_port(3773)
          machine.wait_until_succeeds(as_user("op", "t3ctl auth session list"), timeout=120)
    '';
  in {
    checks.t3code-user = pkgs.testers.runNixOSTest {
      name = "t3code-user";
      nodes.machine = {
        imports = [self.nixosModules.t3code common];
        services.t3code.policy = policy "${fakeProvider}";
      };
      testScript = ''
        ${pyCommon}
        server_up()

        # Identity, exposure, state permissions.
        assert machine.succeed("systemctl show -p User --value t3code.service").strip() == "t3"
        machine.succeed("ss -ltn | grep -q '127.0.0.1:3773 '")
        machine.fail("ss -ltn | grep -q '0.0.0.0:3773 '")
        assert machine.succeed("stat -c %a:%U /var/lib/t3code/.t3/userdata").strip() == "700:t3"
        assert machine.succeed("stat -c %a /var/lib/t3code").strip() == "711"
        machine.fail(as_user("op", "cat /var/lib/t3code/.t3/userdata/statev2.sqlite"))
        machine.fail(as_user("op", "${t3code}/bin/t3 --base-dir /var/lib/t3code/.t3 auth session list"))
        machine.fail(as_user("t3", "cat /home/op/.bash_history || cat /home/op/.profile || ls /home/op/"))
        # No way up from t3 (no doas rule, no wheel).
        machine.fail(as_user("t3", "doas -n -u root true"))

        # The user manager exists for T3's agent scopes (PAMName=login).
        pid = machine.succeed("systemctl show -p MainPID --value t3code.service").strip()
        machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ | grep -q '^XDG_RUNTIME_DIR=/run/user/'")
        machine.fail("journalctl -u t3code.service | grep -q 'Agent scopes are off'")

        # The CLI through t3ctl (doas → t3) works; the same token works over HTTP from op's shell.
        tok = machine.succeed(as_user("op", "t3ctl auth session issue --scope orchestration:read --ttl 5m --token-only")).strip()
        assert len(tok) > 20, tok
        code = machine.succeed(as_user("op", f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Authorization: Bearer {tok}' http://127.0.0.1:3773/api/projects")).strip()
        assert code in ("200", "204"), code
        code = machine.succeed(as_user("op", "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3773/api/projects")).strip()
        assert code in ("401", "403"), code

        # A thread from the CLI reaches the provider as t3, in a T3-made worktree.
        machine.succeed(as_user("op", "t3ctl project add /var/lib/t3code/projects/alpha"))
        machine.succeed(as_user("op", "t3ctl thread start --provider claudeAgent --model claude-sonnet-5 --worktree main /var/lib/t3code/projects/alpha hello"))
        rec = kv(wait_thread_run("/var/lib/t3code", "t3"))
        assert rec["user"] == "t3", rec
        assert rec["pwd"].startswith("/var/lib/t3code/.t3/worktrees/alpha/"), rec["pwd"]
        assert "SSH_AUTH_SOCK" not in rec, rec
        machine.succeed(as_user("t3", f"git -C {rec['pwd']} status --porcelain=2"))
      '';
    };

    checks.t3code-broker = pkgs.testers.runNixOSTest {
      name = "t3code-broker";
      nodes.machine = {config, ...}: {
        imports = [self.nixosModules.t3code self.nixosModules.agent-broker common];
        services.t3code = {
          policy = policy "${config.services.agent-broker.wrapperPackage}/bin/fake-brokered";
          settings.providerInstances.claudeAgent.config.homePath = "/var/lib/agents/alpha/claude";
          environment.T3CODE_TERMINAL_SHELL = "${config.services.agent-broker.wrapperPackage}/bin/t3-terminal-shell";
        };
        services.agent-broker = {
          enable = true;
          commands.fake = "${fakeProvider}";
          packages = [pkgs.coreutils pkgs.git pkgs.bashInteractive pkgs.curl];
          projects.alpha = {
            path = "/var/lib/t3code/projects/alpha";
            limits.memoryMax = "512M";
          };
          projects.beta = {
            path = "/var/lib/t3code/projects/beta";
            claudeConfigDir = null;
          };
        };
        # An attachment T3 would have stored, and an owner-only file next to it.
        systemd.services.t3code-test-attachment = {
          wantedBy = ["multi-user.target"];
          after = ["t3code.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "t3";
            UMask = "0002";
          };
          script = ''
            # T3 makes attachments/ with its umask (0002) and secrets/ 0700.
            install -d -m 775 /var/lib/t3code/.t3/userdata/attachments
            install -d -m 700 /var/lib/t3code/.t3/userdata/secrets
            echo hi > /var/lib/t3code/.t3/userdata/attachments/x.txt
          '';
        };
      };
      testScript = ''
        ${pyCommon}
        server_up()
        machine.wait_for_unit("t3code-test-attachment.service")
        machine.wait_for_unit("agent-broker.socket")

        wt = "/var/lib/t3code/.t3/worktrees/alpha/wt-1"
        machine.succeed(as_user("t3", f"git -C /var/lib/t3code/projects/alpha worktree add -q {wt} -b wt-1"))
        assert machine.succeed(f"stat -c %G:%a {wt}").strip().startswith("proj-alpha:277"), machine.succeed(f"stat -c %G:%a {wt}")

        def brokered(cmd, user="t3", cwd=wt):
            return as_user(user, f"cd {cwd} && {cmd}")

        # 1-4, 7, 8: identity, env scrub, filesystem fences, caps, network, in one run.
        out = kv(machine.succeed(brokered("fake-brokered probe")))
        rec = kv(latest_run("/var/lib/agents/alpha", "agent-alpha"))
        assert rec["user"] == "agent-alpha" and rec["home"] == "/var/lib/agents/alpha" and rec["pwd"] == wt, rec
        assert "SSH_AUTH_SOCK" not in rec and "GH_TOKEN" not in rec, rec
        assert out["config-dir"] == "/var/lib/agents/alpha/claude", out
        expect = dict(
            write_worktree="ok", git_commit="ok", read_attachment="ok", write_attachment="fail",
            read_db="fail", read_secrets="fail", read_beta="fail", read_op_home="fail",
            write_etc="fail", write_store="fail", read_nix_socket="ok", loopback="ok", outside_net="fail",
        )
        got = {k.replace("-", "_"): v for k, v in out.items()}
        bad = {k: (got.get(k), v) for k, v in expect.items() if got.get(k) != v}
        assert not bad, f"probes: {bad}\n{out}"
        assert "/agents-alpha.slice/agent-alpha-" in out["cgroup"], out["cgroup"]
        assert out["memory-max"] == str(512 * 1024 * 1024), out["memory-max"]

        # 2: stdio passthrough across the UID switch, and exit codes.
        assert machine.succeed(brokered("echo ping | fake-brokered cat")).strip() == "ping"
        status, _ = machine.execute(brokered("fake-brokered exit 7"))
        assert status == 7, status

        # 5: git both ways. The agent committed in probe; t3 reads and writes the same worktree.
        machine.succeed(as_user("t3", f"git -C {wt} log -1 --format=%s | grep -q 'agent commit'"))
        machine.succeed(as_user("t3", f"git -C {wt} status --porcelain=2 && echo t3 > {wt}/t3-file && git -C {wt} add -A && git -C {wt} commit -q -m t3"))
        machine.succeed(brokered("fake-brokered probe >/dev/null && git log -1 --format=%s | grep -q '^agent commit$'"))
        # Files t3 wrote are writable by the agent; files the agent wrote are removable by t3.
        machine.succeed(as_user("agent-alpha", f"test -w {wt}/t3-file"))
        machine.succeed(as_user("t3", f"rm {wt}/agent-file"))
        # The agent's git did not need safe.directory from the system: its own gitconfig has it.
        machine.succeed(as_user("agent-alpha", "grep -q 'directory = /var/lib/t3code/projects/alpha' ~/.gitconfig"))

        # 6: lifetime. Killing the wrapper's process group as t3 stops the unit.
        # The wrapper runs where T3 would run it: as t3, in its own cgroup (a stand-in for T3's scope).
        machine.succeed(f"systemd-run --unit=t3-stand-in --uid=t3 --working-directory={wt} -- fake-brokered sleep 300")
        machine.wait_until_succeeds("systemctl list-units --no-legend 'agent-alpha-*' | grep -q service", timeout=30)
        machine.succeed("pgrep -u agent-alpha -x sleep")
        machine.succeed("systemctl kill -s KILL t3-stand-in.service")
        machine.wait_until_fails("systemctl list-units --no-legend 'agent-alpha-*' | grep -q service", timeout=30)
        machine.wait_until_fails("pgrep -u agent-alpha -x sleep", timeout=30)

        # 9: refusals.
        status, err = machine.execute(brokered("fake-brokered exit 0 2>&1", cwd="/tmp"))
        assert status == 125 and "no registered project" in err, (status, err)
        status, err = machine.execute(brokered("CLAUDE_CONFIG_DIR=/var/lib/agents/beta/claude fake-brokered exit 0 2>&1"))
        assert status == 125 and "CLAUDE_CONFIG_DIR" in err, (status, err)
        # On the agent's PATH but not an allowed command (/bin/sh would be: it is the terminal shell).
        status, err = machine.execute(brokered("agent-brokered /run/current-system/sw/bin/true 2>&1"))
        assert status == 125 and "not allowed" in err, (status, err)
        # op is not in the socket group (and could not even enter the worktree).
        status, err = machine.execute(brokered("fake-brokered exit 0 2>&1", user="op", cwd="/tmp"))
        assert status == 126 and "cannot reach the broker" in err, (status, err)
        # beta has no Claude: a run there must not get a config dir.
        out = kv(machine.succeed(brokered("fake-brokered probe", cwd="/var/lib/t3code/projects/beta")))
        assert out["config-dir"] == "unset", out
        rec = kv(latest_run("/var/lib/agents/beta", "agent-beta"))
        assert rec["user"] == "agent-beta", rec

        # 10: a T3 terminal is a shell as the project's user.
        out = machine.succeed(brokered("script -qec 't3-terminal-shell -c \"id -un; tty\"' /dev/null"))
        assert "agent-alpha" in out and "/dev/pts/" in out, out

        # End to end: a T3 thread (CLI → server → wrapper as t3 → broker → unit).
        machine.succeed(as_user("op", "t3ctl project add /var/lib/t3code/projects/alpha"))
        machine.succeed(as_user("op", "t3ctl thread start --provider claudeAgent --model claude-sonnet-5 --worktree main /var/lib/t3code/projects/alpha hello"))
        rec = kv(wait_thread_run("/var/lib/agents/alpha", "agent-alpha"))
        assert rec["user"] == "agent-alpha", rec
        assert rec["pwd"].startswith("/var/lib/t3code/.t3/worktrees/alpha/"), rec["pwd"]
        assert rec["CLAUDE_CONFIG_DIR"] == "/var/lib/agents/alpha/claude", rec
        assert "SSH_AUTH_SOCK" not in rec, rec
        # T3's own worktree inherited the project group, so both sides can work in it.
        assert machine.succeed(f"stat -c %G {rec['pwd']}").strip() == "proj-alpha"
        machine.succeed(as_user("t3", f"git -C {rec['pwd']} status --porcelain=2"))
        machine.wait_until_fails("systemctl list-units --no-legend 'agent-alpha-*' | grep -q service", timeout=60)
      '';
    };
  };
}
