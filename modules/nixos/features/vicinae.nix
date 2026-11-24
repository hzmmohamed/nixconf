{self, ...}: {
  # Vicinae — Raycast-style launcher (apps, file search, calculator, emoji,
  # extensions). Runs as a user daemon bound to the graphical session; the
  # compositor only needs to bind `vicinae toggle`.
  #
  # Theme: one TOML rendered per mode from the palette (preferences.theme.files)
  # and linked as ~/.config/vicinae/themes/nixconf-{light,dark}.toml; vicinae
  # picks the variant from the portal colour scheme (written by theme-mode),
  # and the reload hook re-applies it after a wallpaper palette changed.
  flake.nixosModules.vicinae = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    theme = config.preferences.theme;
    d = self.design;

    # Panel conventions: surface + hairline border, cards on surface-low, the
    # chosen row by inversion (≥7:1), toolkit text selection in selection /
    # on-selection, focus ring in the focus colour.
    mkVicinaeTheme = p: ''
      [meta]
      version = 1
      name = "Nixconf ${
        if p.isDark
        then "Dark"
        else "Light"
      }"
      description = "Generated from the desktop palette (preferences.theme)."
      variant = "${
        if p.isDark
        then "dark"
        else "light"
      }"

      [colors.core]
      background = "${p.surface}"
      foreground = "${p.fg}"
      secondary_background = "${p.surfaceContainerLow}"
      border = "${p.outlineVariant}"
      accent = "${p.accent}"
      accent_foreground = "${p.onAccent}"

      [colors.main_window]
      border = "${p.outlineVariant}"

      [colors.settings_window]
      border = "${p.outlineVariant}"

      [colors.accents]
      blue = "${p.info}"
      green = "${p.success}"
      magenta = "${p.pink}"
      orange = "${p.warning}"
      purple = "${p.mauve}"
      red = "${p.error}"
      yellow = "${p.yellow}"
      cyan = "${p.teal}"

      [colors.shortcut]
      border = "${p.outlineVariant}"

      [colors.text]
      default = "${p.fg}"
      muted = "${p.fgMuted}"
      danger = "${p.error}"
      success = "${p.success}"
      placeholder = "${p.fgMuted}"
      selection = { background = "${p.selection}", foreground = "${p.onSelection}" }

      [colors.text.links]
      default = "${p.accentText}"
      visited = "${p.mauve}"

      [colors.input]
      border = "${p.outlineVariant}"
      border_focus = "${p.focus}"
      border_error = "${p.error}"

      [colors.button.primary]
      background = "${p.surfaceContainer}"
      foreground = "${p.fg}"
      hover = { background = "${p.surfaceContainerHigh}" }
      focus = { outline = "${p.focus}" }

      [colors.list.item.hover]
      foreground = "${p.fg}"
      secondary_foreground = "${p.fgMuted}"

      [colors.list.item.selection]
      background = "${p.inverseSurface}"
      foreground = "${p.onInverseSurface}"
      secondary_background = "${p.inverseSurface}"
      secondary_foreground = "${p.onInverseSurface}"

      [colors.grid.item]
      background = "${p.surfaceContainerLow}"
      hover = { outline = "${p.outline}" }
      selection = { outline = "${p.focus}" }
    '';

    # Root list curation. The root search has no categories: favorites sit on
    # top while the query is empty, everything else is frecency-ranked, and an
    # alias that prefix-matches the query always ranks first. Entrypoint IDs
    # are "<provider>:<entrypoint>"; desktop entries are
    # "applications:<desktop file id minus .desktop>", built-ins are listed in
    # vicinae's src/server/src/extensions/*/ (e.g. "core:about"). IDs a host
    # doesn't have are ignored, so one list serves every host.
    favorites = [
      "applications:kitty"
      "applications:firefox"
      "applications:thunar"
      "applications:codium"
      "clipboard:history"
      "wm:switch-windows"
      "applications:network-menu"
      "applications:removable-media"
      "applications:sway-shortcuts"
      "system:browse-apps"
    ];

    aliases = {
      "applications:network-menu" = "net";
      "applications:removable-media" = "drives";
      "applications:caffeine" = "cf";
      "applications:sway-shortcuts" = "keys";
      "applications:firefox" = "ff";
      "applications:codium" = "code";
      "applications:thunar" = "fm";
      "applications:org.keepassxc.KeePassXC" = "kp";
      "clipboard:history" = "cb";
      "core:search-emojis" = "emoji";
      "wm:switch-windows" = "win";
      "system:browse-apps" = "apps";
    };

    # Off by default upstream: the full app list, A–Z, as its own view.
    shown = ["system:browse-apps"];

    hidden =
      map (id: "applications:${id}") [
        # toolkit demos and dev tools pulled in as dependencies
        "org.gtk.Demo4"
        "org.gtk.gtk4.NodeEditor"
        "org.gtk.PrintEditor4"
        "org.gtk.Shaper"
        "org.gtk.WidgetFactory4"
        "evtest-qt"
        "lsp-plugins"
        "qt5ct"
        "qt6ct"
        "nixos-manual"
        # helpers and secondary windows of apps that have a main entry
        "foot-server"
        "footclient"
        "thunar-settings"
        "blueman-adapters"
        "cups"
        "carla-control"
        "meshchat-launcher"
        "protontricks"
        "gammastep-indicator"
        "org.kde.kdeconnect.nonplasma"
        "startcenter" # LibreOffice start centre; Writer/Calc/… are listed
        "vicinae" # the launcher itself
        # fixed caffeine durations: the "Caffeine: keep awake" toggle stays,
        # the duration picker is `caffeine menu`
        "caffeine-30m"
        "caffeine-1h"
        "caffeine-2h"
        "caffeine-off"
      ]
      ++ [
        # vicinae housekeeping, links and stores (extensions aren't declarative)
        "core:about"
        "core:report-bug"
        "core:documentation"
        "core:join-discord-server"
        "core:sponsor"
        "core:open-default-config"
        "core:prune-memory"
        "core:forget-telemetry"
        "core:oauth-token-store"
        "core:search-builtin-icons"
        "core:inspect-local-storage"
        "core:list-extensions"
        "core:reload-scripts"
        "core:store"
        "raycast-compat:store"
        "developer:create"
        "browser-extension:browse-tabs" # need vicinae's browser extension
        "browser-extension:shortcut-active-tab"
        "theme:set" # the theme follows the palette (theme-mode)
        "power:soft-reboot"
      ];

    at = id: value: let
      parts = lib.splitString ":" id;
    in {
      ${lib.head parts}.entrypoints.${lib.concatStringsSep ":" (lib.tail parts)} = value;
    };
    entrypointSettings = lib.foldl' lib.recursiveUpdate {} (
      map (id: at id {enabled = false;}) hidden
      ++ map (id: at id {enabled = true;}) shown
      ++ lib.mapAttrsToList (id: alias: at id {inherit alias;}) aliases
    );
  in {
    preferences.theme = {
      files."vicinae.toml" = mkVicinaeTheme;
      reloadHooks.vicinae = "${lib.getExe pkgs.vicinae} theme set \"nixconf-$mode\" >/dev/null 2>&1 || true";
    };

    # vicinae's input server injects keystrokes through /dev/uinput for
    # "paste to active window" (emoji picker, snippets). Without it, actions
    # fall back to copying to the clipboard.
    hardware.uinput.enable = true;
    users.users.${user}.extraGroups = ["uinput"];

    home-manager.users.${user} = {config, ...}: let
      home = config.home.homeDirectory;
    in {
      # Both variants, each pointing at its mode's rendered file (Catppuccin
      # store paths, or the wallpaper palette cache).
      home.file = {
        ".config/vicinae/themes/nixconf-light.toml".source =
          config.lib.file.mkOutOfStoreSymlink "${theme.stateDir}/light/vicinae.toml";
        ".config/vicinae/themes/nixconf-dark.toml".source =
          config.lib.file.mkOutOfStoreSymlink "${theme.stateDir}/dark/vicinae.toml";
      };

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
          # Default: a click only selects a list/grid item and a double-click
          # opens it (SelectableDelegate.qml), so a single click looked broken.
          activate_on_single_click = true;
          favicon_service = "none";

          # Palette themes (above). vicinae follows the portal's
          # org.freedesktop.appearance color-scheme (written by darkman via
          # dconf → xdg-desktop-portal-gtk), so this switches live.
          theme = {
            light.name = "nixconf-light";
            dark.name = "nixconf-dark";
          };

          # Opaque, no blur/glass. Same chrome as swaync and tooltips: the
          # panel radius, a hairline border, no shadow.
          launcher_window = {
            opacity = 1.0;
            material = "none";
            rounding = d.panel.radius;
            client_side_decorations = {
              enabled = true;
              border_width = d.panel.border;
              shadow_size = 0;
            };
          };

          inherit favorites;
          fallbacks = ["files:search"];

          providers = lib.recursiveUpdate entrypointSettings {
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
