# T3 Code (agent inbox), self-contained: package, managed policy, settings,
# server unit, project registration and client entry. Spec:
# docs/plans/2026-11-17-t3code-integration.md. Behaviour follows
# preferences.agents.role (set by agent-host / agent-client):
#   - host:   `t3 serve` as a systemd user service bound to 127.0.0.1 and
#             published on the tailnet with `--tailscale-serve`
#             (https://<host>.<tailnet>.ts.net/, MagicDNS certificate; never
#             Funnel). Needs the user to be Tailscale operator (agent-host).
#   - client: the T3 Code desktop app (pair it with each host once) plus a
#             browser shortcut to preferences.agents.target.
#
# Declarative control lives in /etc/t3code/policy.json (T3's managed policy),
# validated at build time with `t3 policy check`. settings.json and
# keybindings.json stay mutable (the server rewrites both; a store symlink
# breaks every write) — HM only merges a few keys into them on activation.
#
# Never run `t3 up`, `t3 service install`, `t3 update` or `t3 connect` here.
{inputs, ...}: {
  flake.nixosModules.agent-t3code = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.agents.t3code;
    agents = config.preferences.agents;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    llm = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    userBin = "/etc/profiles/per-user/${user}/bin";
    t3 = lib.getExe' cfg.package "t3";

    setting = value: locked: {inherit value locked;};

    # Keys the packaged T3 rejects go to cfg.policyExtraSettings once it
    # supports them (0.1.9 rejects keepAwakeWhileAgentsWork and
    # requireConnectDeviceApproval, both new in 0.1.10).
    limitsOff = {
      connect = false; # T3 Connect (third-party relay + Clerk)
      webhookTasks = false;
      telemetry = false;
      browserCookieImport = false;
      updates = {
        mode = "off"; # Nix owns updates
        allowNightly = false;
      };
    };

    hostPolicy = {
      schemaVersion = 1;
      organization = "nixconf (${user})";
      settings =
        {
          enableProviderUpdateChecks = setting false false;
          # Ask before edits and commands; switch per thread in the UI.
          defaultRuntimeMode = setting "approval-required" false;
          defaultThreadEnvMode = setting "worktree" false;
          worktreeSubmodules = setting "none" false;
          automaticGitFetchInterval = setting 300000 false;
          worktreesDirectory = setting "${home}/.t3/worktrees" true;
          defaultModelSelection =
            setting {
              instanceId = "claudeAgent";
              model = "claude-opus-5-5";
            }
            false;
          # Titles, branch names, commit/PR text. The default is Codex, which
          # is not installed.
          textGenerationModelSelection =
            setting {
              instanceId = "claudeAgent";
              model = "claude-haiku-5-5";
            }
            false;
          branchNamingMode = setting "semantic" false;
          defaultAutoPull = setting true false;
          "storageCleanup.logsAfterDays" = setting 30 false;
        }
        // cfg.policyExtraSettings;
      limits =
        limitsOff
        // {
          providers = {
            allowedDrivers = ["claudeAgent" "opencode"];
            # Stable profile paths: a CLI bump reaches new sessions without
            # restarting T3. Claude is the claude-code input's build (the
            # HM wrapper with plugins + MCP), OpenCode the agent-opencode one.
            instances = {
              claudeAgent = {
                locked = true;
                binaryPath = "${userBin}/claude";
              };
              opencode = {
                locked = true;
                binaryPath = "${userBin}/opencode";
              };
            };
          };
        };
    };

    # The desktop client checks its own update feed unless told not to.
    clientPolicy = {
      schemaVersion = 1;
      organization = "nixconf (${user})";
      limits = limitsOff;
    };

    # Build-time gate: a key this T3 version can't enforce fails the build,
    # not the service (which refuses to start on unknown keys).
    checkedPolicy = policy:
      pkgs.runCommand "t3code-policy.json" {
        nativeBuildInputs = [cfg.package];
        json = builtins.toJSON policy;
        passAsFile = ["json"];
      } ''
        export HOME=$TMPDIR
        t3 policy check "$jsonPath"
        cp "$jsonPath" "$out"
      '';

    policyFile = checkedPolicy (
      if agents.role == "host"
      then hostPolicy
      else clientPolicy
    );

    httpsUrl =
      if agents.target != null && agents.tailnetDomain != null
      then "https://${agents.target}.${agents.tailnetDomain}/"
      else null;

    registerProjects = pkgs.writeShellApplication {
      name = "t3code-projects";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        # `t3 project add` exits non-zero for an already-registered project,
        # so failures are reported but never fatal.
        sleep 5
        for p in ${lib.escapeShellArgs agents.projects}; do
          if [ ! -d "$p" ]; then
            echo "t3code-projects: skipping $p (not checked out here)"
            continue
          fi
          ${t3} project add --base-dir "$HOME/.t3" --title "$(basename "$p")" "$p" \
            || echo "t3code-projects: $p not added (already registered?)"
        done
      '';
    };
  in {
    options.preferences.agents.t3code = {
      package = lib.mkOption {
        type = lib.types.package;
        default = llm.t3code.override {providerPackages = [];};
        defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.t3code.override { providerPackages = []; }";
        description = ''
          T3 Code package. Without bundled provider CLIs (-2.2 GiB): T3 uses
          the Claude/OpenCode binaries pinned in the policy.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3773;
        description = "Loopback port of the server (Tailscale Serve proxies HTTPS :443 to it).";
      };

      policyExtraSettings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        example = lib.literalExpression ''
          {
            keepAwakeWhileAgentsWork = { value = true; locked = false; };
          }
        '';
        description = ''
          Extra managed-policy settings (host role), for keys newer T3
          versions accept. Checked at build time with `t3 policy check`.
        '';
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = httpsUrl;
        defaultText = lib.literalExpression ''"https://''${target}.''${tailnetDomain}/"'';
        description = "Server URL a client opens (Tailscale Serve HTTPS).";
      };
    };

    config = lib.mkMerge [
      {environment.etc."t3code/policy.json".source = policyFile;}

      (lib.mkIf (agents.role == "host") {
        home-manager.users.${user} = {
          programs.t3code = {
            enable = true;
            inherit (cfg) package;
            # mutableUserSettings stays at its default (true): merged on
            # activation, otherwise owned by the server. `enabled` is set at
            # instance level (a config.enabled triggers a migration rewrite);
            # binary paths come from the policy.
            userSettings.providerInstances = {
              claudeAgent = {
                driver = "claudeAgent";
                enabled = true;
              };
              opencode = {
                driver = "opencode";
                enabled = true;
              };
            };
          };

          # T3 runs every agent/terminal in a transient scope under
          # app-t3code-agents-<hash>.slice (child of app-t3code.slice): cap the
          # parent like agents.slice. The server itself stays outside it so it
          # outlives its agents under memory pressure.
          systemd.user.slices.app-t3code = {
            Unit.Description = "T3 Code agents and terminals";
            Slice = {
              MemoryHigh = "60%";
              MemoryMax = "75%";
              CPUWeight = 50;
              IOWeight = 50;
            };
          };

          systemd.user.services.t3code = {
            Unit = {
              Description = "T3 Code server (loopback + Tailscale Serve)";
              After = ["network-online.target"];
              StartLimitIntervalSec = 300;
              StartLimitBurst = 5;
              # The policy is only read at startup.
              X-Restart-Triggers = ["${policyFile}"];
            };
            Service = {
              ExecStart = lib.concatStringsSep " " [
                t3
                "serve --mode web --no-browser"
                "--host 127.0.0.1 --port ${toString cfg.port}"
                "--tailscale-serve --tailscale-serve-port 443"
                "--base-dir %h/.t3 %h"
              ];
              WorkingDirectory = "%h";
              Environment = [
                # tailscale, systemd-run, git, gh from the system profile.
                "PATH=${userBin}:/run/current-system/sw/bin:/run/wrappers/bin"
                "T3CODE_TELEMETRY_ENABLED=false"
              ];
              # Mirrors T3's own boot-service unit.
              KillMode = "mixed";
              OOMPolicy = "continue";
              Restart = "always";
              RestartSec = 5;
              TimeoutStopSec = 90;
              CPUWeight = 1000;
              IOWeight = 1000;
              MemoryLow = "1536M";
              ManagedOOMPreference = "avoid";
            };
            Install.WantedBy = ["default.target"];
          };

          systemd.user.services.t3code-projects = lib.mkIf (agents.projects != []) {
            Unit = {
              Description = "Register T3 Code projects";
              After = ["t3code.service"];
              Requires = ["t3code.service"];
            };
            Service = {
              Type = "oneshot";
              ExecStart = lib.getExe registerProjects;
            };
            Install.WantedBy = ["t3code.service"];
          };
        };
      })

      (lib.mkIf (agents.role == "client") {
        home-manager.users.${user} = {
          # Desktop app as a remote-only client: turn off Settings ->
          # Environments -> Local environment, then pair each host
          # (`ssh <host> t3 pair --label <client>`).
          home.packages = [cfg.package.desktop];

          xdg.desktopEntries = lib.mkIf (cfg.url != null) {
            t3code-remote = {
              name = "T3 Code web (${agents.target})";
              genericName = "Coding agent inbox";
              exec = "${lib.getExe' pkgs.xdg-utils "xdg-open"} ${cfg.url}";
              icon = "utilities-terminal";
              categories = ["Development"];
            };
          };
        };
      })
    ];
  };
}
