# services.t3code: T3 Code's server as its own system user
# (docs/plans/2026-11-28-t3-separate-user-spike.md §2). Reusable, host-agnostic;
# nixconf's `agent-t3code` keeps the policy, projects and desktop wiring and
# will move onto this module host by host.
#
# What it does: a user (default `t3`, home /var/lib/t3code, no wheel), a
# system unit running `t3 serve` on loopback with `PAMName=login` (a user
# manager for T3's agent scopes), a settings merge before start, an optional
# root `tailscale serve` oneshot (the server user is not the Tailscale
# operator), the managed policy under /etc/t3code, and `t3ctl`: every `t3`
# CLI command opens the server's SQLite/key files directly, so operators run
# them as the server user through doas.
{...}: {
  flake.nixosModules.t3code = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.t3code;
    t3 = lib.getExe' cfg.package "t3";
    baseDir = "${cfg.home}/.t3";
    stateDir = "${baseDir}/userdata";

    # Build-time gate: a key this T3 version can't enforce fails the build,
    # not the service (which refuses to start on unknown keys).
    policyFile =
      pkgs.runCommand "t3code-policy.json" {
        nativeBuildInputs = [cfg.package];
        json = builtins.toJSON cfg.policy;
        passAsFile = ["json"];
      } ''
        export HOME=$TMPDIR
        t3 policy check "$jsonPath"
        cp "$jsonPath" "$out"
      '';

    settingsFile = pkgs.writeText "t3code-settings.json" (builtins.toJSON cfg.settings);

    gitconfig = pkgs.writeText "t3-gitconfig" ''
      # Managed by services.t3code.
      [core]
      	sharedRepository = group
      ${cfg.gitconfig}
    '';

    # Everything the server runs with; t3ctl reproduces it for the CLI.
    serviceEnv =
      {
        HOME = cfg.home;
        T3CODE_HOME = baseDir;
        T3CODE_TELEMETRY_ENABLED = "false";
        PATH = lib.makeBinPath (cfg.path ++ [pkgs.coreutils pkgs.git pkgs.bashInteractive]) + ":/run/current-system/sw/bin";
      }
      // cfg.environment;

    t3ctl = pkgs.writeShellScriptBin "t3ctl" ''
      # t3ctl <t3 subcommand…>: the T3 CLI as the server user (${cfg.user}).
      # The CLI signs itself in by opening the server's files (0700), so it
      # has to run as that user. Usage: t3ctl pair --label phone; t3ctl auth
      # session list; t3ctl project add <path>; t3ctl thread start <project> "<msg>".
      exec /run/wrappers/bin/doas -u ${cfg.user} ${lib.getExe' pkgs.coreutils "env"} -i \
        ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") serviceEnv)} \
        ${t3} --base-dir ${baseDir} "$@"
    '';
  in {
    options.services.t3code = {
      enable = lib.mkEnableOption "the T3 Code server as a dedicated system user";

      package = lib.mkPackageOption pkgs "t3code" {};

      user = lib.mkOption {
        type = lib.types.str;
        default = "t3";
      };
      group = lib.mkOption {
        type = lib.types.str;
        default = "t3";
      };
      uid = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Fixed uid (keeps ACLs and worktree ownership stable across reinstalls).";
      };
      home = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/t3code";
        description = "HOME of the server; T3's data lives in <home>/.t3 (userdata is 0700, home and .t3 are 0711 so agents can traverse to what is bound for them).";
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["kvm" "render"];
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3773;
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };

      tailscaleServe = {
        enable = lib.mkEnableOption "publishing the loopback port on the tailnet (root `tailscale serve`, no operator needed)";
        port = lib.mkOption {
          type = lib.types.port;
          default = 443;
        };
      };

      policy = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "T3 managed policy (/etc/t3code/policy.json), validated with `t3 policy check` at build time. {} writes none.";
      };
      settings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Keys deep-merged into <home>/.t3/userdata/settings.json before each start (T3 keeps rewriting the file; a store symlink would break that).";
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {T3CODE_TERMINAL_SHELL = "/run/current-system/sw/bin/t3-terminal-shell";};
      };
      path = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
        description = "Extra packages on the server's PATH (providers, systemd, gh, …).";
      };
      gitconfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Appended to the server user's ~/.gitconfig (core.sharedRepository=group is always set).";
      };

      operators = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Users who get `t3ctl` (a doas rule to run as the server user).";
      };
      operatorsNoPass = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "doas rule without a password (tests; or hosts where doas is passwordless anyway).";
      };
    };

    config = lib.mkIf cfg.enable {
      users.users.${cfg.user} = {
        isSystemUser = true;
        inherit (cfg) group home uid extraGroups;
        createHome = true;
        homeMode = "0711";
        shell = pkgs.bashInteractive;
        linger = true;
        description = "T3 Code server";
      };
      users.groups.${cfg.group} = {};

      environment.etc = lib.mkIf (cfg.policy != {}) {
        "t3code/policy.json".source = policyFile;
      };

      systemd.tmpfiles.rules = [
        "d ${baseDir} 0711 ${cfg.user} ${cfg.group} -"
        "d ${baseDir}/worktrees 0755 ${cfg.user} ${cfg.group} -"
        "L+ ${cfg.home}/.gitconfig - - - - ${gitconfig}"
      ];

      # settings.json merge, then the server.
      systemd.services.t3code-settings = {
        description = "T3 Code settings merge";
        before = ["t3code.service"];
        requiredBy = ["t3code.service"];
        after = ["systemd-tmpfiles-setup.service"];
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          UMask = "0077";
        };
        path = [pkgs.jq pkgs.coreutils];
        script = ''
          mkdir -p ${stateDir}
          f=${stateDir}/settings.json
          if [ -s "$f" ]; then
            jq -s '.[0] * .[1]' "$f" ${settingsFile} > "$f.tmp"
          else
            cp ${settingsFile} "$f.tmp"
          fi
          mv "$f.tmp" "$f"
        '';
      };

      systemd.services.t3code = {
        description = "T3 Code server (${cfg.user}, loopback)";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target" "systemd-tmpfiles-setup.service"];
        wants = ["network-online.target"];
        restartTriggers = lib.optional (cfg.policy != {}) policyFile;
        environment = builtins.removeAttrs serviceEnv ["PATH"];
        path = cfg.path ++ [pkgs.coreutils pkgs.git pkgs.bashInteractive "/run/current-system/sw"];
        serviceConfig = {
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = cfg.home;
          # A PAM session: logind starts user@<uid>, XDG_RUNTIME_DIR is set, and
          # T3's `systemd-run --user --scope` agent scopes work.
          PAMName = "login";
          UMask = "0002";
          ExecStart = lib.concatStringsSep " " [
            t3
            "serve --mode web --no-browser"
            "--host ${cfg.host} --port ${toString cfg.port}"
            "--base-dir ${baseDir} ${cfg.home}"
          ];
          # Mirrors T3's own boot-service unit.
          KillMode = "mixed";
          OOMPolicy = "continue";
          Restart = "always";
          RestartSec = 5;
          TimeoutStopSec = 90;
          ManagedOOMPreference = "avoid";
          NoNewPrivileges = true;
        };
      };

      # Publish the loopback service on the tailnet (HTTPS, MagicDNS cert).
      # Runs as root, so it does not depend on the operator setting.
      systemd.services.t3code-tailscale-serve = lib.mkIf cfg.tailscaleServe.enable {
        description = "Tailscale Serve for the T3 Code server";
        after = ["tailscaled.service" "t3code.service"];
        wants = ["tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [config.services.tailscale.package pkgs.coreutils];
        script = ''
          for _ in $(seq 60); do
            if tailscale serve --bg --https=${toString cfg.tailscaleServe.port} http://127.0.0.1:${toString cfg.port}; then
              exit 0
            fi
            sleep 5
          done
          echo "tailscale serve failed (logged in? HTTPS certificates enabled for the tailnet?)" >&2
          exit 1
        '';
      };

      environment.systemPackages = lib.mkIf (cfg.operators != []) [t3ctl];
      security.doas = lib.mkIf (cfg.operators != []) {
        enable = true;
        extraRules = [
          {
            users = cfg.operators;
            runAs = cfg.user;
            persist = !cfg.operatorsNoPass;
            noPass = cfg.operatorsNoPass;
            keepEnv = false;
          }
        ];
      };
    };
  };
}
