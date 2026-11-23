# T3 Code (agent inbox), self-contained: package, managed policy, settings,
# server unit, projects, desktop app, devices. Spec:
# docs/plans/2026-11-17-t3code-integration.md (§9: the 2026-11-17 rework).
#
# Model (T3 0.1.9): every machine is a full T3 *environment* (its own server,
# SQLite store and project rows). A project lives per environment; the client
# groups rows of the same git remote into one logical project and picks the
# environment per thread. Server-to-server *links* (Labs) let one
# environment's agents launch threads on another (`delegate_task`,
# `t3_thread_launch` with an environmentId); `t3-link <host>` sets one up.
#
#   - server (cfg.server.enable; default on agent hosts, also on hazel):
#     `t3 serve` as a systemd user service on 127.0.0.1, published on the
#     tailnet with `--tailscale-serve` (https://<host>.<tailnet>.ts.net/).
#   - desktop (cfg.desktop.enable; default on GUI hosts): the Electron app,
#     remote-only (its own "local environment" would fight the systemd server
#     over ~/.t3 and quit), paired with the local server over loopback and
#     with the other hosts over the tailnet. Patched so a Sway key can trigger
#     snapshots (0.1.9 only has GNOME/KDE/Hyprland/Niri triggers).
#
# Declarative control lives in /etc/t3code/policy.json (T3's managed policy),
# validated at build time with `t3 policy check`. settings.json,
# keybindings.json, client-settings.json and desktop-settings.json stay
# mutable (T3 rewrites them; a store symlink breaks every write): activation
# only merges a few keys into them.
#
# Never run `t3 up`, `t3 service install`, `t3 update` or `t3 connect` here.
{
  inputs,
  self,
  ...
}: {
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
    hostName = config.networking.hostName;
    llm = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    userBin = "/etc/profiles/per-user/${user}/bin";
    t3 = lib.getExe' cfg.package "t3";
    android = cfg.devices.android;

    setting = value: locked: {inherit value locked;};

    # One claudeAgent instance per Claude subscription (agent-common).
    claudeInstances = lib.mapAttrs' (_: a: lib.nameValuePair a.instanceId a) agents.claudeAccounts;
    personalInstance =
      lib.findFirst (a: a.configDir == ".claude") {instanceId = "claudeAgent";}
      (lib.attrValues agents.claudeAccounts);

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

    serverPolicy = {
      schemaVersion = 1;
      organization = "nixconf (${user})";
      settings =
        {
          enableProviderUpdateChecks = setting false false;
          # Ask before edits and commands; switch per thread in the UI.
          defaultRuntimeMode = setting "approval-required" false;
          # Threads share the main checkout by default; pick worktree per thread
          # for long, dependency-changing or run-producing streams (each repo's
          # AGENTS.md says when).
          defaultThreadEnvMode = setting "local" false;
          worktreeSubmodules = setting "none" false;
          automaticGitFetchInterval = setting 300000 false;
          worktreesDirectory = setting "${home}/.t3/worktrees" true;
          defaultModelSelection =
            setting {
              inherit (personalInstance) instanceId;
              model = "claude-opus-5-5";
            }
            false;
          # Titles, branch names, commit/PR text. The default is Codex, which
          # is not installed (and 0.1.9's Claude default, claude-haiku-5-5,
          # is not a valid model id).
          textGenerationModelSelection =
            setting {
              inherit (personalInstance) instanceId;
              model = "claude-sonnet-5";
            }
            false;
          branchNamingMode = setting "semantic" false;
          defaultAutoPull = setting true false;
          "storageCleanup.logsAfterDays" = setting 30 false;
          # Voice: Parakeet Unified English 0.6B (the dictation feature puts
          # T3's exact catalog file in ~/.cache/huggingface, so "Download"
          # links it offline). Hosts can shorten the unload timeout.
          speechModelId = setting "handy-computer/parakeet-unified-en-0.6b-gguf" false;
          speechModelUnloadTimeout = setting "min_15" false;
          # Labs: server-to-server links (`t3-link`). Must be on at both ends.
          linkedEnvironmentsEnabled = setting true false;
        }
        // lib.optionalAttrs android.enable {
          enableDeviceSupport = setting true false;
          # Environment-wide default (project-scoped in T3, but project ids
          # are random UUIDs): agents may drive the emulator.
          enableAgentDeviceAccess = setting true false;
        }
        // cfg.policyExtraSettings;
      limits =
        limitsOff
        // {
          providers = {
            allowedDrivers = ["claudeAgent" "opencode"];
            # Keyed by *driver*: the pin applies to every instance of it
            # (claudeAgent and claudeWork alike) and recreates the default
            # `claudeAgent` instance. Only binaryPath/launchArgs/environment
            # can be pinned; each instance keeps its own homePath.
            # Stable profile paths: a CLI bump reaches new sessions without
            # restarting T3. Claude is the claude-code input's build (the
            # HM wrapper with plugins + MCP), OpenCode the agent-opencode
            # one; both run through agent-devshell (agent-common) so threads
            # start inside the project's direnv dev shell when one is ready.
            instances = {
              claudeAgent = {
                locked = true;
                binaryPath = "${userBin}/claude-devshell";
              };
              opencode = {
                locked = true;
                binaryPath = "${userBin}/opencode-devshell";
              };
            };
          };
        };
    };

    # A desktop-only machine (no server) still keeps the app's update feed off.
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
      if cfg.server.enable
      then serverPolicy
      else clientPolicy
    );

    # T3 environments in the registry: agent hosts plus role "t3" (hazel).
    t3Hosts = lib.filterAttrs (_: h: lib.any (r: lib.elem r (h.roles or [])) ["agent-host" "t3"]) self.hosts;
    t3HostUrl = name: h: "https://${h.tailnetName or name}.${agents.tailnetDomain}/";
    remoteT3Hosts = lib.filterAttrs (n: _: n != hostName) t3Hosts;
    hostCases = hosts:
      lib.concatStringsSep "\n  " (lib.mapAttrsToList (n: h: "${n}) url=${t3HostUrl n h} ;;") hosts);
    defaultRemoteHost =
      if agents.target != null
      then agents.target
      else lib.findFirst (_: true) null (lib.attrNames remoteT3Hosts);

    # `t3-open [host]`: a host's web UI as a standalone Chromium app window
    # (falls back to the default browser). The desktop app is the main UI;
    # this is the zero-pairing fallback.
    hmChromium = config.home-manager.users.${user}.programs.chromium;
    t3Open = pkgs.writeShellApplication {
      name = "t3-open";
      runtimeInputs = [pkgs.xdg-utils];
      text = ''
        # Usage: t3-open [host]   (default: ${toString defaultRemoteHost})
        host=''${1:-${toString defaultRemoteHost}}
        case "$host" in
          ${hostCases t3Hosts}
          *) echo "t3-open: unknown T3 host '$host' (known: ${lib.concatStringsSep " " (lib.attrNames t3Hosts)})" >&2; exit 1 ;;
        esac
        ${
          if hmChromium.enable
          then ''exec ${lib.getExe hmChromium.finalPackage} --app="$url"''
          else ''exec xdg-open "$url"''
        }
      '';
    };

    # `t3-link <host> [access]`: let this environment's agents launch threads
    # on <host> (one direction; run it on the other side for the reverse).
    # Mints a 5-minute pairing code there over SSH and links with it. Links
    # last 30 days (T3 0.1.9), then re-run.
    t3Link = pkgs.writeShellApplication {
      name = "t3-link";
      runtimeInputs = [pkgs.openssh pkgs.gnused pkgs.coreutils];
      text = ''
        if [ "$#" -lt 1 ]; then
          echo "usage: t3-link <host> [read-only|approval-required|auto-accept-edits|auto|full-access]" >&2
          echo "hosts: ${lib.concatStringsSep " " (lib.attrNames remoteT3Hosts)}" >&2
          exit 2
        fi
        host=$1
        access=''${2:-approval-required}
        case "$host" in
          ${hostCases remoteT3Hosts}
          *) echo "t3-link: unknown T3 host '$host' (known: ${lib.concatStringsSep " " (lib.attrNames remoteT3Hosts)})" >&2; exit 1 ;;
        esac
        code=$(ssh "$host" t3 pair --label "${hostName}-link" --ttl 5m | sed -n 's/^Token: //p')
        if [ -z "$code" ]; then
          echo "t3-link: no pairing code from $host (is t3code.service running there?)" >&2
          exit 1
        fi
        exec ${t3} environment link --base-dir "$HOME/.t3" "$url" \
          --pairing-code "$code" --access "$access"
      '';
    };

    registerProjects = pkgs.writeShellApplication {
      name = "t3code-projects";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        # `t3 project add` exits non-zero for an already-registered project,
        # so failures are reported but never fatal.
        sleep 5
        # An array, so a single project doesn't trip shellcheck SC2043.
        projects=(${lib.escapeShellArgs agents.projects})
        for p in "''${projects[@]}"; do
          if [ ! -d "$p" ]; then
            echo "t3code-projects: skipping $p (not checked out here)"
            continue
          fi
          ${t3} project add --base-dir "$HOME/.t3" --title "$(basename "$p")" "$p" \
            || echo "t3code-projects: $p not added (already registered?)"
        done
      '';
    };

    # The server's agent browser (headless tabs, and every tab when no
    # desktop app spawned the server) is a pinned Chrome-for-Testing
    # chrome-headless-shell that T3 downloads into ~/.t3/tools; it can't run
    # on NixOS. T3 only checks that the versioned path is an executable file,
    # so point it at nixpkgs Chromium (same major). The version is read from
    # the bundle so a T3 bump keeps working.
    browserLink = pkgs.writeShellApplication {
      name = "t3code-browser-link";
      runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused];
      text = ''
        dist=${cfg.package.unwrapped}/libexec/t3code/apps/server/dist
        ver=$(grep -h -A1 '^// src/preview/PreviewBrowser.ts' "$dist"/*.mjs \
          | sed -n 's/^const VERSION = "\([0-9.]*\)";/\1/p' | head -n1)
        if [ -z "$ver" ]; then
          echo "t3code-browser-link: chrome-headless-shell version not found in $dist" >&2
          exit 0
        fi
        dir="$HOME/.t3/tools/chrome-headless-shell/linux64/$ver"
        mkdir -p "$dir"
        ln -sfn ${lib.getExe cfg.browser.package} "$dir/chrome-headless-shell"
      '';
    };

    # Desktop app with one patch: on Sway, register the D-Bus capture endpoint
    # T3 otherwise only offers on Niri (com.t3tools.T3Code.SnapShot,
    # /com/t3tools/SnapShot, com.t3tools.SnapShot.Capture). The capture then
    # falls through to Electron's picker (xdg-desktop-portal-wlr ScreenCast +
    # PipeWire). Only dist-electron is copied; the rest is symlinked, and the
    # build fails if the patched line moves in a newer T3.
    desktopInner = cfg.package.unwrapped.desktop;
    desktopSway =
      pkgs.runCommand "t3code-desktop-${cfg.package.version}-sway" {
        nativeBuildInputs = [pkgs.makeBinaryWrapper];
      } ''
        src=${desktopInner}/libexec/t3code/apps/desktop
        app=$out/libexec/t3code/apps/desktop
        mkdir -p "$app" "$out/bin" "$out/share/applications"
        for e in "$src"/*; do
          [ "$(basename "$e")" = dist-electron ] || ln -s "$e" "$app/"
        done
        ln -s ${desktopInner}/libexec/t3code/apps/server $out/libexec/t3code/apps/server
        cp -r --no-preserve=mode "$src/dist-electron" "$app/"
        substituteInPlace "$app/dist-electron/main.cjs" \
          --replace-fail 'if (mode === "portal" && niriSocketPath()) {' \
                         'if (mode === "portal" && (niriSocketPath() || process.env.SWAYSOCK)) {'

        # The same Electron the upstream wrapper uses (read from it).
        electron=$(grep -aoE '/nix/store/[a-z0-9]{32}-electron-[0-9.]+/bin/electron' \
          ${desktopInner}/bin/t3code-desktop | head -n1)
        test -x "$electron"
        makeWrapper "$electron" "$out/bin/t3code-desktop" \
          --add-flags "$app" \
          --set-default T3CODE_DESKTOP_LAUNCHER_PATH "$out/bin/t3code-desktop" \
          --inherit-argv0

        ln -s ${desktopInner}/share/icons $out/share/icons
        cat >$out/share/applications/t3code.desktop <<EOF
        [Desktop Entry]
        Type=Application
        Name=T3 Code
        GenericName=Coding agent inbox
        Comment=Control surface for coding agents
        Exec=t3code-desktop %U
        Icon=t3code
        StartupWMClass=com.t3tools.T3Code
        Categories=Development;
        EOF
      '';

    # Sway binding target: ask the running desktop app for a snapshot.
    t3Snapshot = pkgs.writeShellApplication {
      name = "t3-snapshot";
      runtimeInputs = [pkgs.glib];
      text = ''
        exec gdbus call --session --dest com.t3tools.T3Code.SnapShot \
          --object-path /com/t3tools/SnapShot --method com.t3tools.SnapShot.Capture
      '';
    };

    # desktop-settings.json: remote-only (no desktop-spawned server).
    desktopSettings = pkgs.writeText "t3code-desktop-settings.json" (builtins.toJSON {
      localEnvironmentEnabled = false;
    });
    desktopSettingsMerge = pkgs.writeShellApplication {
      name = "t3code-desktop-settings";
      runtimeInputs = [pkgs.jq pkgs.coreutils];
      text = ''
        f="$HOME/.t3/userdata/desktop-settings.json"
        mkdir -p "$(dirname "$f")"
        cur='{}'
        if [ -e "$f" ]; then
          if ! cur=$(jq -e . "$f" 2>/dev/null); then
            echo "t3code-desktop-settings: $f is not valid JSON, leaving it untouched" >&2
            exit 0
          fi
        fi
        new=$(jq -n --argjson cur "$cur" --slurpfile s ${desktopSettings} '$cur * $s[0]')
        if [ "$new" = "$cur" ]; then exit 0; fi
        tmp=$(mktemp "$f.XXXXXX")
        printf '%s\n' "$new" >"$tmp"
        mv -f "$tmp" "$f"
      '';
    };

    # `t3-android-sdk`, run inside the project's Android shell
    # (`rl-dev-mobile -c t3-android-sdk` for routelab): exposes that shell's
    # SDK to the T3 server at a stable path, GC-rooted, with the
    # `cmdline-tools/latest` T3 requires (routelab pins cmdline-tools 11.0).
    androidSdkLink = pkgs.writeShellApplication {
      name = "t3-android-sdk";
      runtimeInputs = [pkgs.coreutils pkgs.findutils config.nix.package pkgs.systemd];
      text = ''
        if [ -z "''${ANDROID_HOME:-}" ]; then
          echo "t3-android-sdk: ANDROID_HOME is unset; run it inside the project's Android dev shell" >&2
          exit 1
        fi
        sdk=$(readlink -f "$ANDROID_HOME")
        case "$sdk" in
          /nix/store/*) ;;
          *) echo "t3-android-sdk: $sdk is not in the Nix store" >&2; exit 1 ;;
        esac
        target=${lib.escapeShellArg android.sdk}
        state=$(dirname "$target")
        mkdir -p "$state"
        # Keep the SDK alive after the dev shell's profile moves on.
        nix-store --add-root "$state/sdk-gcroot" --indirect --realise "$(echo "$sdk" | cut -d/ -f1-4)" >/dev/null

        new=$(mktemp -d "$state/.sdk.XXXXXX")
        for e in "$sdk"/*; do ln -s "$e" "$new/"; done
        if [ ! -e "$sdk/cmdline-tools/latest" ] && [ -d "$sdk/cmdline-tools" ]; then
          rm "$new/cmdline-tools"
          mkdir "$new/cmdline-tools"
          for v in "$sdk"/cmdline-tools/*; do ln -s "$v" "$new/cmdline-tools/"; done
          newest=$(find "$sdk/cmdline-tools" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -n1)
          ln -s "$sdk/cmdline-tools/$newest" "$new/cmdline-tools/latest"
        fi
        # Swap in, then drop the old tree (symlinks only).
        if [ -d "$target" ] && [ ! -L "$target" ]; then
          old=$(mktemp -u "$state/.sdk-old.XXXXXX")
          mv "$target" "$old"
          mv "$new" "$target"
          find "$old" -depth \( -type l -o -type d \) -delete
        else
          mv -T "$new" "$target"
        fi
        echo "t3-android-sdk: $target -> $sdk"
        systemctl --user try-restart t3code.service
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

      server = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = agents.role == "host";
          defaultText = lib.literalExpression ''preferences.agents.role == "host"'';
          description = "Run this machine's own T3 environment (`t3 serve` user service).";
        };
        tailscaleServe = lib.mkOption {
          type = lib.types.bool;
          default = agents.tailnetDomain != null;
          defaultText = lib.literalExpression "preferences.agents.tailnetDomain != null";
          description = "Publish the server as https://<host>.<tailnet>.ts.net/ (Tailscale Serve).";
        };
      };

      desktop = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = config.preferences.desktop.enable;
          defaultText = lib.literalExpression "preferences.desktop.enable";
          description = "Install the T3 Code desktop app (remote-only when the server runs here).";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = desktopSway;
          defaultText = lib.literalExpression "cfg.package.unwrapped.desktop, patched for Sway snapshots";
          description = "Desktop app package.";
        };
      };

      browser = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = cfg.server.enable && config.preferences.desktop.enable;
          defaultText = lib.literalExpression "server.enable && preferences.desktop.enable";
          description = ''
            Point the server's agent browser (chrome-headless-shell) at a Nix
            Chromium. Off on headless hosts (closure size).
          '';
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.chromium;
          defaultText = lib.literalExpression "pkgs.chromium";
          description = "Chromium the server's agent browser runs (major version should match T3's pin).";
        };
      };

      devices.android = {
        enable = lib.mkEnableOption "T3 device support with this host's Android emulator (KVM)";
        sdk = lib.mkOption {
          type = lib.types.str;
          default = "${home}/.local/share/t3-android/sdk";
          description = "ANDROID_HOME for the server; `t3-android-sdk` fills it from a project's dev shell.";
        };
        avdHome = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "ANDROID_AVD_HOME (AVDs T3 lists and boots). null: ~/.android/avd.";
        };
        userHome = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "ANDROID_USER_HOME. null: ~/.android.";
        };
        emulatorArgs = lib.mkOption {
          type = lib.types.str;
          default = "-no-window -gpu swiftshader_indirect -no-audio -no-boot-anim -no-snapshot -memory 4096 -cores 6";
          description = ''
            EXPO_DEVICE_HUB_EMULATOR_EXTRA_ARGS: flags for emulators T3 boots.
            Headless (T3 streams the screen), so it also works with no monitor.
          '';
        };
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
          Extra managed-policy settings (server machines), for keys newer T3
          versions accept. Checked at build time with `t3 policy check`.
        '';
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if agents.target != null && agents.tailnetDomain != null
          then "https://${agents.target}.${agents.tailnetDomain}/"
          else null;
        defaultText = lib.literalExpression ''"https://''${target}.''${tailnetDomain}/"'';
        description = "URL of the default remote server (Tailscale Serve HTTPS).";
      };
    };

    config = lib.mkMerge [
      {environment.etc."t3code/policy.json".source = policyFile;}

      (lib.mkIf cfg.server.enable {
        home-manager.users.${user} = {
          home.packages =
            [
              # `t3-pair <label>`: pairing link/QR on the tailnet HTTPS name (not
              # the LAN IP), so phones and other hosts can scan it directly.
              (pkgs.writeShellScriptBin "t3-pair" ''
                exec ${t3} pair --base-dir "$HOME/.t3" --tailscale \
                  --tailscale-serve-port 443 --label "''${1:-device}" "''${@:2}"
              '')
            ]
            ++ lib.optional (agents.tailnetDomain != null && remoteT3Hosts != {}) t3Link;

          programs.t3code = {
            enable = true;
            inherit (cfg) package;
            # mutableUserSettings stays at its default (true): merged on
            # activation, otherwise owned by the server. `enabled` is set at
            # instance level (a config.enabled triggers a migration rewrite);
            # binary paths come from the policy, config dirs from here.
            userSettings.providerInstances =
              lib.mapAttrs (_: a:
                {
                  driver = "claudeAgent";
                  enabled = true;
                  inherit (a) displayName;
                }
                // lib.optionalAttrs (a.configDir != ".claude") {
                  config.homePath = "${home}/${a.configDir}";
                })
              claudeInstances
              // {
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

          # Idle cost is a Node process with timers (git fetch, provider
          # health, power monitor); hazel tunes them with the
          # backgroundActivity profile in its policy, not with unit limits.
          # No ConditionACPower: on battery is exactly when hazel works alone.
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
              ExecStartPre = lib.mkIf cfg.browser.enable ["-${lib.getExe browserLink}"];
              ExecStart = lib.concatStringsSep " " (
                [
                  t3
                  "serve --mode web --no-browser"
                  "--host 127.0.0.1 --port ${toString cfg.port}"
                ]
                ++ lib.optional cfg.server.tailscaleServe "--tailscale-serve --tailscale-serve-port 443"
                ++ ["--base-dir %h/.t3 %h"]
              );
              WorkingDirectory = "%h";
              Environment =
                [
                  # tailscale, systemd-run, git, gh from the system profile;
                  # node/npm + ffmpeg (libx264) for the device hub.
                  "PATH=${lib.makeBinPath (lib.optionals android.enable [pkgs.nodejs pkgs.ffmpeg-full])}:${userBin}:/run/current-system/sw/bin:/run/wrappers/bin"
                  "T3CODE_TELEMETRY_ENABLED=false"
                  # transcribe.cpp's libggml-vulkan dlopens libvulkan.so.1;
                  # without it voice transcription silently runs on the CPU.
                  "LD_LIBRARY_PATH=${pkgs.vulkan-loader}/lib"
                ]
                # programs.direnv sets DIRENV_CONFIG for login shells only;
                # without it agents' own `direnv exec . <cmd>` falls back to
                # direnv's built-in use_flake instead of nix-direnv.
                ++ lib.optional config.programs.direnv.enable "DIRENV_CONFIG=/etc/direnv"
                ++ lib.optionals android.enable (
                  [
                    "ANDROID_HOME=${android.sdk}"
                    "EXPO_DEVICE_HUB_EMULATOR_EXTRA_ARGS=${android.emulatorArgs}"
                  ]
                  ++ lib.optional (android.avdHome != null) "ANDROID_AVD_HOME=${android.avdHome}"
                  ++ lib.optional (android.userHome != null) "ANDROID_USER_HOME=${android.userHome}"
                );
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

      (lib.mkIf cfg.desktop.enable {
        home-manager.users.${user} = {
          home.packages = [cfg.desktop.package t3Snapshot];

          programs.t3code = {
            enable = true;
            # HM's default would install nixpkgs' (old) t3code.
            package = lib.mkIf (!cfg.server.enable) null;
            # Ctrl+Enter sends, Enter is a newline (client-settings.json is
            # per device, not per server).
            clientSettings.sendShortcut = "mod-enter";
          };

          # The app's own local environment would start a second server on
          # ~/.t3, get "state dir owned" from the systemd one and quit.
          home.activation.t3codeDesktopSettings = lib.mkIf cfg.server.enable {
            after = ["writeBoundary"];
            before = [];
            data = "run ${lib.getExe desktopSettingsMerge}";
          };

          # Snapshot of a window/screen into the current draft (portal picker).
          wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
            "Mod4+Ctrl+s" = "exec ${lib.getExe t3Snapshot}";
          };
        };
      })

      # Web fallbacks (vicinae lists them): "T3 Code web (<host>)" for the
      # other T3 hosts. "T3 Code" itself is the desktop app.
      (lib.mkIf (config.preferences.desktop.enable && agents.tailnetDomain != null && remoteT3Hosts != {}) {
        home-manager.users.${user} = {
          home.packages = [t3Open];
          xdg.desktopEntries = lib.mapAttrs' (n: _:
            lib.nameValuePair "t3code-${n}" {
              name = "T3 Code web (${n})";
              genericName = "Coding agent inbox";
              exec = "${lib.getExe t3Open} ${n}";
              icon = "t3code";
              categories = ["Development"];
            })
          remoteT3Hosts;
        };
      })

      (lib.mkIf android.enable {
        # The emulator needs KVM (/dev/kvm is root:kvm).
        users.users.${user}.extraGroups = ["kvm"];
        home-manager.users.${user}.home.packages = [androidSdkLink];
      })
    ];
  };
}
