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
      # No extra resource controls on vicinae.service: the file indexer is
      # already a separate helper process (libexec/vicinae-file-indexer)
      # whose scan threads drop themselves to nice 19 + idle I/O class and
      # back off on /proc/pressure/io. Service-wide Nice/IOScheduling* would
      # only slow the launcher UI (and ioprio is a no-op on NVMe's default
      # `none` scheduler on both butternut and hazel).

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

            # File index (vicinae 0.23.2 source, src/file-indexer/): a helper
            # process keeps an sqlite FTS5 trigram index in
            # ~/.cache/vicinae/file-indexer/file-indexer.db. Every start runs
            # an "incremental (exhaustive)" scan that walks the whole tree,
            # one stat per directory to compare against the last scan; after
            # that inotify (home + 2 levels, plus the 2048 most recently
            # changed dirs) and a depth-5 sweep every minute keep it fresh.
            # The only knobs are `autoIndexing`, `indexingPaths` and
            # `excludedIndexingPaths`: no interval, depth or ignore-file
            # setting.
            #
            # Built-in skips: symlinks (nix `result` links), .git, .cache,
            # node_modules, venvs, __pycache__, .gradle, .terraform,
            # CACHEDIR.TAG dirs, *.noindex, and a few toolchain stores.
            # .gitignore is NOT honoured (the ignore-file filter exists but
            # is never enabled, still true in 0.30.1), so gitignored build or
            # data dirs have to be listed here. Excludes are exact
            # directory paths (no globs); missing ones are harmless.
            #
            # 2026-11 on butternut: 635k entries / 790 MB DB, cold startup
            # walk 14.7 s (790 MB read back from the DB); this list cuts it to
            # ~95k. Third-party clones, generated output and app state are
            # never what you look for in a launcher (editors/fd cover code).
            files.preferences = {
              autoIndexing = true;
              indexingPaths = [home];
              excludedIndexingPaths = map (p: "${home}/${p}") [
                # app data, toolchains, caches
                ".local/share" # app data, Steam, containers, reference-repos store
                ".local/state"
                ".npm"
                ".cargo"
                ".rustup"
                ".gradle"
                ".android"
                ".m2"
                ".bun"
                ".yarn"
                ".jdks"
                ".julia"
                ".eclipse"
                ".kube" # discovery cache
                ".continue" # LanceDB embeddings index
                ".claude" # agent transcripts, plugin caches
                ".codex"
                ".steam"
                ".wine"
                ".wine-cutting"
                ".wine-paint"
                "go"
                "Games"
                ".mozilla"
                ".thunderbird"
                ".config/chromium"
                ".config/VSCodium"
                ".config/Lens"
                ".config/Insomnia"
                ".config/superpowers"
                ".vscode-oss"
                "Desktop/Old Firefox Data"
                "personal/pictures/.dtrash" # darktable trash

                # reference clones and dev environments
                "nixconf/.repos"
                "nixconf/.devenv"
                "nixconf/.direnv"
                "work/personal/nixpkgs"
                "work/oss/matsim-libs"
                "work/tfc/matsim-libs"
                "work/tfc/experiments/matsim-libs"
                "work/tfc/repos/.agentic-onboarding" # agent worktrees duplicate the repos
                "work/tfc/repos/routelab-monorepo/.repos"
                "work/tfc/repos/routelab-monorepo/.devenv"
                "work/tfc/repos/cairo-abm-viz/.repos"
                "work/tfc/repos/cairo-abm-viz/.devenv"
                "work/tfc/repos/d_abm/.repos"
                "work/freelance/nur/.agents"

                # gitignored build output and data
                "work/tfc/repos/d_abm/output"
                "work/tfc/repos/d_abm/data"
                "work/tfc/repos/eg-abm/.synpp_cache"
                "work/tfc/repos/gkma-ridership/vendor"
                "work/tfc/repos/routelab-monorepo/apps/observer/android/app/build"
                "work/tfc/repos/cairo-abm-viz/apps/observer/android/app/build"
                "work/tfc/repos/observer-mobile-app-archive/android/app/build"
              ];
            };
          };
        };
      };
    };
  };
}
