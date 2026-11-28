# OpenCode 2 (llm-agents `opencode2`, exposed as `opencode`), self-contained.
# Spec: docs/plans/2026-11-17-opencode-integration.md. Behaviour follows
# preferences.agents.role (set by agent-host / agent-client):
#   - every machine: the `opencode` wrapper (autoupdate off, free models off,
#     claude-agent pinned to the claude-code input, declarative cli.json
#     content) + opencode.json (2.x shape: providers, MCP, skills, policies).
#   - host:   the shared background service (`opencode serve --service`) as
#             a user unit in agents.slice on 127.0.0.1:<port>, published on
#             the tailnet by `tailscale serve` (HTTPS :<tailscaleServePort>).
#             TUIs, herdr panes and T3 Code reuse it (same version: one
#             flake.lock for every host).
#   - client: `oc [dir]` attaches the TUI to the target's service.
#
# What stays mutable by design: ~/.local/share/opencode (sessions,
# credentials from `opencode auth login`, saved approvals), cli.json (the env
# content overrides it) and ~/.config/opencode/service.json (managed keys are
# merged in on activation).
{inputs, ...}: {
  flake.nixosModules.agent-opencode = {
    config,
    lib,
    pkgs,
    ...
  }: let
    agents = config.preferences.agents;
    cfg = agents.opencode;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    system = pkgs.stdenv.hostPlatform.system;
    llm = inputs.llm-agents.packages.${system};
    # Same Claude Code as the VSCodium extension and the HM `claude` (unwrapped:
    # the Agent SDK passes its own flags and settings).
    claudePkg = inputs.claude-code.packages.${system}.claude-code;
    hmCfg = config.home-manager.users.${user};

    # cli.json content (TUI). Merged over the app-owned cli.json while set.
    cliSettings = {
      "$schema" = "https://opencode.ai/v2/cli.json";
      theme = {
        name = "catppuccin";
        mode = "system";
      };
      animations = false;
      session = {
        thinking = "hide";
        permissions = "prompt";
        tps = false;
      };
      # Vertical tabs; hidden inside herdr.
      tabs = {
        mode = "auto";
        scope = "cwd";
        layout = "vertical";
        indicators = "status";
      };
      diffs = {
        source = "branch";
        view = "auto";
        tree = true;
      };
      attention = {
        notifications = true;
        sound = false;
      };
      terminal = {
        title = true;
        copy = "select";
      };
      highlights = false;
    };

    opencode = pkgs.symlinkJoin {
      name = "opencode-${llm.opencode2.version}";
      inherit (llm.opencode2) version;
      paths = [llm.opencode2];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        rm "$out/bin/opencode2"
        makeWrapper ${lib.getExe llm.opencode2} "$out/bin/opencode" \
          --set OPENCODE_DISABLE_AUTOUPDATE 1 \
          --set OPENCODE_DISABLE_FREE_MODELS 1 \
          --set OPENCODE_CLAUDE_PATH ${lib.getExe claudePkg} \
          --set-default OPENCODE_CLI_CONFIG_CONTENT ${lib.escapeShellArg (builtins.toJSON cliSettings)} \
          --prefix PATH : ${lib.makeBinPath [pkgs.git pkgs.direnv]}
      '';
      meta = llm.opencode2.meta // {mainProgram = "opencode";};
    };

    # programs.mcp servers (agent-common) in the 2.x shape; HM 26.05's
    # enableMcpIntegration would emit the 1.x one.
    mcpServers =
      lib.mapAttrs (
        _: s:
          if (s.url or null) != null
          then
            {
              type = "remote";
              inherit (s) url;
            }
            // lib.optionalAttrs ((s.headers or {}) != {}) {inherit (s) headers;}
          else
            {
              type = "local";
              command = [s.command] ++ (s.args or []);
            }
            // lib.optionalAttrs ((s.env or {}) != {}) {
              environment = lib.mapAttrs (_: v:
                if builtins.isAttrs v
                then "{file:${v.file}}"
                else v)
              s.env;
            }
      )
      hmCfg.programs.mcp.servers;

    model = name: context: output: tools: {
      inherit name;
      capabilities = {
        inherit tools;
        input = ["text"];
        output = ["text"];
      };
      limit = {inherit context output;};
      cost = {
        input = 0;
        output = 0;
      };
    };

    # The one guidelines file every agent reads: `preferences.agents.guidelinesFile`
    # (agent-common/agent-env.nix, which also installs it at
    # ~/.config/agents/guidelines.md and wires Claude's CLAUDE.md import
    # line) — a shared option rather than a path reaching into agent-env's
    # own file layout, so this feature doesn't depend on another feature's
    # internals. OpenCode 2.x's `instructions` config reads each entry as a
    # file and folds its content into context — confirmed from the packaged
    # opencode2 binary (llm-agents input): the normalizer validates
    # `instructions` as a string array (`kH(e.instructions, ...)`) and a
    # document loader reads each path's content
    # (`Me.type==="document"?Me.info.instructions??[]`, then read with a
    # 5s cache). That's a single source of truth, so it's used here instead
    # of also installing a global `~/.config/opencode/AGENTS.md` (the binary
    # does read one automatically too, resolved from the app config dir, but
    # duplicating the content there would just be a second copy to drift).
    guidelinesFile = config.preferences.agents.guidelinesFile;

    settings = {
      update = "disable";
      share = "disabled";
      model = "claude-agent/opus";
      default_agent = "build";
      instructions = ["${guidelinesFile}"];

      # Last match wins; unmatched = ask.
      permissions = [
        {
          action = "external_directory";
          resource = "*";
          effect = "ask";
        }
        {
          action = "external_directory";
          resource = "~/work/*";
          effect = "allow";
        }
        {
          action = "external_directory";
          resource = "/nix/store/*";
          effect = "allow";
        }
        {
          action = "edit";
          resource = "/nix/store/*";
          effect = "deny";
        }
        {
          action = "shell";
          resource = "git push *";
          effect = "ask";
        }
      ];
      # Policies can only turn an effect into deny and outrank projects and
      # "allow always". Same lists as Claude's managed denies
      # (preferences.agents.deny). A policy matches "<action>:<resource>"
      # with `*` = any text; a read/edit resource is the absolute path
      # (relative only inside the session's project), and policies don't
      # expand `~`, so paths are spelled out here.
      policies = let
        deny = resource: {
          action = "tool.use";
          inherit resource;
          effect = "deny";
        };
        abs = p:
          if lib.hasPrefix "~/" p
          then "${home}/${lib.removePrefix "~/" p}"
          else p;
        glob = p:
          if lib.hasInfix "*" p
          then abs p
          else "${abs p}/*";
      in
        map (cmd: deny "shell:${cmd}") (agents.deny.commands
          ++ [
            "git push --force*"
            "git push -f *"
          ])
        ++ lib.concatMap (p: [(deny "read:${glob p}") (deny "edit:${glob p}")]) agents.deny.paths;

      compaction = {
        auto = true;
        keep.tokens = 20000;
        buffer = "15%";
      };
      experimental.subagent_depth = 2;

      # ~/.claude/skills (anthropic skills from agent-common) is read
      # automatically; Claude Code plugins are not, so add superpowers.
      skills = ["${inputs.superpowers}/skills"];

      mcp.servers = mcpServers;

      agents = {
        plan.model = "claude-agent/opus#high";
        explore.model = "claude-agent/haiku";
        title.model = "claude-agent/haiku";
        summary.model = "claude-agent/haiku";
        local = {
          description = "Mechanical tasks on the local llama-swap model (free, at home only)";
          mode = "primary";
          model = "peacelily/qwen3.5:9b-coding";
        };
        reviewer = {
          description = "Read-only second opinion on a diff or design";
          mode = "subagent";
          model = "claude-agent/sonnet";
          permissions = [
            {
              action = "edit";
              resource = "*";
              effect = "deny";
            }
          ];
        };
      };

      # claude-agent (Claude subscription via the installed `claude`, Agent
      # SDK) and anthropic (API key) are built in. claude-agent is an
      # unofficial route: enabled for the trial, see the spec §3.1.
      providers.peacelily = {
        name = "peacelily (llama-swap)";
        package = "@opencode/ai/providers/openai-compatible";
        settings = {
          baseURL = agents.llamaSwapUrl;
          # llama-swap cold start (healthCheckTimeout = 600 s).
          headerTimeout = 600000;
        };
        compatibility.reasoningField = "reasoning_content";
        # Ids and context sizes match features/ai-server.nix (llama-swap).
        models = {
          "qwen3.5:9b-coding" = model "Qwen3.5 9B coding (64k)" 65536 16384 true;
          "qwen3.5:35b-a3b" = model "Qwen3.5 35B-A3B (64k)" 65536 16384 true;
          "qwen3.5:9b" = model "Qwen3.5 9B thinking (32k)" 32768 8192 true;
          "qwen3.5:9b-nothinker" = model "Qwen3.5 9B (32k)" 32768 8192 true;
          "qwen3.5:4b" = model "Qwen3.5 4B (titles, summaries)" 32768 1024 false;
        };
      };
    };

    passwordFile =
      if cfg.password.enable
      then config.sops.secrets."agents-opencode-password".path
      else null;

    # Managed keys merged into the app-owned service.json (0600).
    serviceMerge = pkgs.writeShellApplication {
      name = "opencode-service-merge";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = ''
        f="$HOME/.config/opencode/service.json"
        mkdir -p "$(dirname "$f")"
        if [ -e "$f" ]; then
          if ! cur=$(jq -e . "$f" 2>/dev/null); then
            echo "opencode-service-merge: $f is not valid JSON, leaving it untouched" >&2
            exit 0
          fi
        else
          cur='{}'
        fi
        pw=""
        pwfile=${lib.escapeShellArg (toString passwordFile)}
        if [ -n "$pwfile" ] && [ -r "$pwfile" ]; then pw=$(tr -d '\n' <"$pwfile"); fi
        new=$(jq --arg pw "$pw" --argjson port ${toString cfg.port} \
          '.hostname = "127.0.0.1" | .port = $port
           | if $pw != "" then .password = $pw else . end' <<<"$cur")
        if [ "$new" = "$cur" ]; then exit 0; fi
        umask 077
        printf '%s\n' "$new" >"$f.tmp"
        mv -f "$f.tmp" "$f"
      '';
    };

    serveUrl = "http://127.0.0.1:${toString cfg.port}";

    # oc [dir]: TUI on hazel, server (tools, files, models) on the target.
    # The directory is a server-side path (checkouts live at the same paths).
    oc = pkgs.writeShellApplication {
      name = "oc";
      runtimeInputs = [pkgs.jq pkgs.openssh pkgs.coreutils];
      text = ''
        target=''${OC_TARGET:-${toString agents.target}}
        if [ -z "$target" ]; then
          echo "oc: no target (set OC_TARGET or preferences.agents.target)" >&2
          exit 2
        fi
        url=''${OC_URL:-https://$target.${toString agents.tailnetDomain}:${toString cfg.tailscaleServePort}}
        if [ -z "''${OPENCODE_PASSWORD:-}" ]; then
          pwfile=${lib.escapeShellArg (toString passwordFile)}
          if [ -n "$pwfile" ] && [ -r "$pwfile" ]; then
            OPENCODE_PASSWORD=$(tr -d '\n' <"$pwfile")
          else
            # No shared secret: read the service's own password over SSH.
            OPENCODE_PASSWORD=$(ssh "$target" cat .config/opencode/service.json | jq -r '.password // empty')
          fi
          export OPENCODE_PASSWORD
        fi
        exec ${lib.getExe opencode} --server "$url" "''${1:-$PWD}"
      '';
    };
  in {
    options.preferences.agents.opencode = {
      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = opencode;
        description = "The wrapped OpenCode 2 package (also what T3 Code runs).";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 49374;
        description = "Loopback port of the background service (OpenCode's default for the latest channel).";
      };

      tailscaleServePort = lib.mkOption {
        type = lib.types.port;
        default = 8443;
        description = "HTTPS port `tailscale serve` publishes the service on (T3 Code has 443).";
      };

      password.enable = lib.mkEnableOption ''
        a shared service password from sops (secrets/shared/agents.yaml, key
        `opencode-password`), merged into service.json on hosts and used by
        `oc` on clients. Off: the service generates its own password and `oc`
        reads it over SSH
      '';

      anthropicApiKey.enable = lib.mkEnableOption ''
        ANTHROPIC_API_KEY for the built-in anthropic provider, from sops
        (secrets/shared/agents.yaml, key `anthropic-api-key`), passed to the
        host service as an environment file (never stored in the DB)
      '';
    };

    config = lib.mkMerge [
      {
        assertions = [
          {
            assertion = agents.role != "client" || (agents.target != null && agents.tailnetDomain != null);
            message = "agent-opencode: a client needs preferences.agents.target and preferences.agents.tailnetDomain for `oc`.";
          }
        ];

        sops.secrets."agents-opencode-password" = lib.mkIf cfg.password.enable {
          sopsFile = ../../.. + "/secrets/shared/agents.yaml";
          key = "opencode-password";
          owner = user;
        };

        home-manager.users.${user} = {
          programs.opencode = {
            enable = true;
            package = opencode;
            # MCP is emitted in the 2.x shape above, not by HM's 1.x integration.
            enableMcpIntegration = false;
            inherit settings;
          };
        };
      }

      (lib.mkIf (agents.role == "host") {
        sops.secrets."agents-anthropic-api-key" = lib.mkIf cfg.anthropicApiKey.enable {
          sopsFile = ../../.. + "/secrets/shared/agents.yaml";
          key = "anthropic-api-key";
        };
        sops.templates."opencode-env" = lib.mkIf cfg.anthropicApiKey.enable {
          owner = user;
          content = "ANTHROPIC_API_KEY=${config.sops.placeholder."agents-anthropic-api-key"}\n";
        };

        # Publish the loopback service on the tailnet (HTTPS, MagicDNS cert).
        # Runs as root, so it does not depend on the operator setting; the
        # serve config persists in tailscaled state. No Funnel.
        systemd.services.opencode-tailscale-serve = {
          description = "Tailscale Serve for the OpenCode service";
          after = ["tailscaled.service" "tailscaled-autoconnect.service" "tailscaled-set.service"];
          wants = ["tailscaled.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [config.services.tailscale.package pkgs.coreutils];
          script = ''
            for _ in $(seq 60); do
              if tailscale serve --bg --https=${toString cfg.tailscaleServePort} ${serveUrl}; then
                exit 0
              fi
              sleep 5
            done
            echo "tailscale serve failed (logged in? HTTPS certificates enabled for the tailnet?)" >&2
            exit 1
          '';
        };

        home-manager.users.${user} = {
          home.activation.opencodeServiceConfig = {
            after = ["writeBoundary"];
            before = [];
            data = "run ${lib.getExe serviceMerge}";
          };

          # The unit *is* the shared service: same-version clients reuse it
          # through ~/.local/state/opencode/service.json. A client-spawned
          # service would live in the client's cgroup, so evict it on start.
          systemd.user.services.opencode = {
            Unit = {
              Description = "OpenCode background service (TUI, web, T3 Code)";
              After = ["network-online.target"];
            };
            Service = {
              ExecStartPre = "-${lib.getExe opencode} service stop";
              ExecStart = "${lib.getExe opencode} serve --service";
              # Not `always`: with a compatible incumbent the process exits 0.
              Restart = "on-failure";
              RestartSec = 5;
              Slice = "agents.slice";
              Environment = [
                "PATH=/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin:/run/wrappers/bin"
              ];
              EnvironmentFile = lib.mkIf cfg.anthropicApiKey.enable config.sops.templates."opencode-env".path;
            };
            Install.WantedBy = ["default.target"];
          };
        };
      })

      (lib.mkIf (agents.role == "client") {
        home-manager.users.${user}.home.packages = [oc];
      })
    ];
  };
}
