# T3 Code (agent inbox web UI), self-contained: package, settings, server
# unit and client shortcut. Behaviour follows preferences.agents.role
# (set by agent-host / agent-client, options from agent-common):
#   - host:   `t3 serve` as a systemd user service in agents.slice, bound to
#             this machine's Tailscale IPv4 (tailscale0 is a trusted firewall
#             interface, so only tailnet devices can reach it) — never 0.0.0.0.
#   - client: desktop entry opening the UI on preferences.agents.target.
#
# HM 26.05 has `programs.t3code` (settings) but not `programs.t3code.server`
# (HM master only), hence the hand-written unit.
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
    llm = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    userBin = "/etc/profiles/per-user/${user}/bin";

    t3serve = pkgs.writeShellApplication {
      name = "t3code-serve";
      runtimeInputs = [config.services.tailscale.package pkgs.coreutils];
      text = ''
        host=${lib.escapeShellArg cfg.host}
        if [ "$host" = tailscale ]; then
          host=""
          for _ in $(seq 60); do
            host=$(tailscale ip -4 2>/dev/null | head -n1 || true)
            [ -n "$host" ] && break
            sleep 5
          done
          if [ -z "$host" ]; then
            echo "t3code-serve: no Tailscale IPv4 address after 5 minutes" >&2
            exit 1
          fi
        fi
        exec ${lib.getExe' cfg.package "t3"} serve --mode web --no-browser \
          --host "$host" --port ${toString cfg.port} "$HOME"
      '';
    };
  in {
    options.preferences.agents.t3code = {
      package = lib.mkOption {
        type = lib.types.package;
        default = llm.t3code;
        defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.t3code";
        description = "T3 Code package (nixpkgs 26.05 only has 0.0.24).";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "tailscale";
        description = ''
          Address the server binds to: "tailscale" (this machine's tailnet
          IPv4, resolved at service start) or a literal address such as
          127.0.0.1. Wildcard addresses are rejected.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3773;
        description = "Server port (T3 Code's default).";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if agents.target != null
          then "http://${agents.target}:${toString cfg.port}"
          else null;
        defaultText = lib.literalExpression ''"http://''${preferences.agents.target}:''${port}"'';
        description = "UI URL a client opens.";
      };
    };

    config = lib.mkMerge [
      (lib.mkIf (agents.role == "host") {
        assertions = [
          {
            assertion = !(builtins.elem cfg.host ["0.0.0.0" "::" "[::]" ""]);
            message = "preferences.agents.t3code.host must not be a wildcard address.";
          }
        ];

        home-manager.users.${user} = {
          programs.t3code = {
            enable = true;
            inherit (cfg) package;
            mutableUserSettings = false;
            # Absolute paths: the t3 wrapper prefixes PATH with its own
            # llm-agents claude/opencode; use the HM-managed ones instead
            # (Claude from the claude-code input, with MCP + plugins wrapper).
            userSettings.providerInstances = {
              claudeAgent = {
                driver = "claudeAgent";
                enabled = true;
                config = {
                  enabled = true;
                  binaryPath = "${userBin}/claude";
                };
              };
              opencode = {
                driver = "opencode";
                enabled = true;
                config = {
                  enabled = true;
                  binaryPath = "${userBin}/opencode";
                };
              };
            };
          };

          systemd.user.services.t3code = {
            Unit.Description = "T3 Code server (tailnet)";
            Service = {
              ExecStart = lib.getExe t3serve;
              Restart = "on-failure";
              RestartSec = 10;
              Slice = "agents.slice";
              Environment = [
                "PATH=${userBin}:/run/current-system/sw/bin:/run/wrappers/bin"
              ];
            };
            Install.WantedBy = ["default.target"];
          };
        };
      })

      (lib.mkIf (agents.role == "client" && cfg.url != null) {
        home-manager.users.${user}.xdg.desktopEntries.t3code-remote = {
          name = "T3 Code (${
            if agents.target != null
            then agents.target
            else "remote"
          })";
          genericName = "Coding agent inbox";
          exec = "${lib.getExe' pkgs.xdg-utils "xdg-open"} ${cfg.url}";
          icon = "utilities-terminal";
          categories = ["Development"];
        };
      })
    ];
  };
}
