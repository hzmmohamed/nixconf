# Compute target for coding agents (design: docs/plans/2026-11-17-agentic-workspace-design.md).
# Import together with `agent-common` (shared agent config) and `agent-t3code`
# (T3 Code server). Adds the herdr server, the `agents.slice` resource caps
# and `agent-run`.
#
# Verify a process is capped:  grep agents.slice /proc/<pid>/cgroup
#   (or `systemctl --user status agents.slice` to list its members).
{inputs, ...}: {
  flake.nixosModules.agent-host = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    llm = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

    # Ad-hoc commands inside the agents slice (runs in the current shell's
    # cwd/env as a transient scope): `agent-run cargo build`.
    agentRun = pkgs.writeShellApplication {
      name = "agent-run";
      runtimeInputs = [pkgs.systemd];
      text = ''
        if [ "$#" -eq 0 ]; then
          echo "usage: agent-run <command> [args...]" >&2
          exit 2
        fi
        exec systemd-run --user --slice=agents.slice --scope --quiet --collect -- "$@"
      '';
    };
  in {
    preferences.agents.role = "host";

    # Agent services must run without a graphical login (headless target).
    users.users.${user}.linger = true;

    # Let the user manager control IO weights too (default: pids memory cpu).
    systemd.services."user@".serviceConfig.Delegate = "pids memory cpu io";

    home-manager.users.${user} = {
      systemd.user.slices.agents = {
        Unit.Description = "Coding agents (T3 Code, herdr, agent-run jobs)";
        Slice = {
          MemoryHigh = "60%";
          MemoryMax = "75%";
          CPUWeight = 50;
          IOWeight = 50;
        };
      };

      # `herdr --remote <this host>` from a client attaches to this server.
      systemd.user.services.herdr = {
        Unit.Description = "herdr agent workspace server";
        Service = {
          ExecStart = "${lib.getExe llm.herdr} server";
          ExecReload = "${lib.getExe llm.herdr} server reload-config";
          Restart = "on-failure";
          RestartSec = 5;
          Slice = "agents.slice";
          Environment = [
            "PATH=/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
          ];
        };
        Install.WantedBy = ["default.target"];
      };

      home.packages = [agentRun];
    };
  };
}
