{
  # Vicinae — Raycast-style launcher (apps, file search, calculator, emoji,
  # extensions). Runs as a user daemon bound to the graphical session; the
  # compositor only needs to bind `vicinae toggle`.
  flake.nixosModules.vicinae = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    # vicinae's input server injects keystrokes through /dev/uinput for
    # "paste to active window" (emoji picker, snippets). Without it, actions
    # fall back to copying to the clipboard.
    hardware.uinput.enable = true;
    users.users.${user}.extraGroups = ["uinput"];

    home-manager.users.${user} = {config, ...}: let
      home = config.home.homeDirectory;
    in {
      # The file indexer runs inside the daemon: lowest best-effort I/O
      # priority so its startup scan yields to everything else at login.
      systemd.user.services.vicinae.Service = {
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };

      programs.vicinae = {
        enable = true;
        systemd = {
          enable = true;
          target = "graphical-session.target";
        };

        settings = {
          telemetry.system_info = false;
          pop_to_root_on_close = true;
          favicon_service = "none";

          # Built-in catppuccin themes. vicinae follows the portal's
          # org.freedesktop.appearance color-scheme (written by darkman via
          # dconf → xdg-desktop-portal-gtk), so this switches live.
          theme = {
            light.name = "catppuccin-latte";
            dark.name = "catppuccin-mocha";
          };

          # Opaque, no blur/glass. Same chrome as swaync and tooltips:
          # 8px radius, 1px border, no shadow.
          launcher_window = {
            opacity = 1.0;
            material = "none";
            rounding = 8;
            client_side_decorations = {
              enabled = true;
              border_width = 1;
              shadow_size = 0;
            };
          };

          favorites = [];
          fallbacks = ["files:search"];

          providers = {
            # Clipboard history (text + images); replaces clipse. Hosts bind
            # a key to `vicinae deeplink vicinae://launch/clipboard/history`.
            # ignorePasswords drops selections offered with the
            # x-kde-passwordManagerHint mime type (password managers,
            # `wl-copy --sensitive`, private browser windows).
            clipboard = {
              enabled = true;
              preferences = {
                monitoring = true;
                ignorePasswords = true;
                eraseOnStartup = false;
              };
            };

            # Launch each app in its own systemd scope instead of inside
            # vicinae.service's cgroup (survives daemon restarts, proper
            # per-app resource accounting).
            applications.preferences.launchPrefix = "${lib.getExe pkgs.app2unit} --";

            # File index: the whole home dir. vicinae already skips symlinks
            # (nix `result` links), VCS dirs, node_modules, .cache, venvs,
            # CACHEDIR.TAG dirs and honours .gitignore; exclude the bulky
            # state dirs it doesn't know about.
            files.preferences = {
              indexingPaths = [home];
              # (2026-11: the startup scan walked 517k files in 14 s and made
              # the first launcher toggles lag; app data and toolchains are
              # never what you search for.)
              excludedIndexingPaths = map (p: "${home}/${p}") [
                ".local/share" # app data, Steam, containers, reference-repos store
                ".local/state"
                ".npm"
                ".cargo"
                ".rustup"
                ".gradle"
                ".android"
                "go"
                "Games"
                "work/tfc/repos/.agentic-onboarding" # agent worktrees duplicate the repos
                ".mozilla"
                ".thunderbird"
                ".config/chromium"
                ".config/VSCodium"
                ".vscode-oss"
              ];
            };
          };
        };
      };
    };
  };
}
