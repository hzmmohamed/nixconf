# Wallpaper subsystem: awww (user service bound to graphical-session.target)
# driven by one command, `set-wallpaper` (see ./set-wallpaper.sh for the
# contract). darkman calls `set-wallpaper --mode light|dark` (through
# preferences.theme.switchCommand), which swaps to the paired default unless
# the user pinned a wallpaper, regenerates the palette for the wallpaper theme
# source, then runs `theme-mode`.
#
# Defaults: a calm, openly licensed light/dark pair from Wikimedia Commons,
# fetched at build time (./meta.json: URL, hash, attribution), installed with a
# `<file>.json` attribution sidecar next to each image, and seeded once into
# ~/Pictures/Wallpapers (a seeded image the user deleted is not re-added).
#
# Sidecar schema (also written by the vicinae wallpaper extension):
#   title, creator, creator_url, license, license_version, license_url,
#   source_url, provider, attribution, fetched_at, sha256
{...}: {
  flake.nixosModules.wallpaper = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.wallpaper;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    themeMode = lib.getExe config.preferences.theme.package;

    meta = lib.importJSON ./meta.json;

    # Store dir with each default image + its sidecar (sha256 of the bytes).
    defaults = pkgs.runCommand "wallpaper-defaults" {nativeBuildInputs = [pkgs.jq];} (
      ''
        mkdir -p $out
      ''
      + lib.concatMapStrings (m: ''
        cp ${pkgs.fetchurl {
          inherit (m) url hash;
          name = m.file;
        }} $out/${m.file}
        jq -n --arg sha "$(sha256sum $out/${m.file} | cut -c1-64)" \
          --argjson m ${lib.escapeShellArg (builtins.toJSON m.sidecar)} \
          '$m + {sha256: $sha}' > $out/${m.file}.json
      '') (builtins.attrValues meta)
    );

    setWallpaper = pkgs.writeShellApplication {
      name = "set-wallpaper";
      runtimeInputs = [
        config.home-manager.users.${user}.services.awww.package
        pkgs.jq
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.util-linux
      ];
      text =
        ''
          DEFAULT_LIGHT=${lib.escapeShellArg cfg.default.light}
          DEFAULT_DARK=${lib.escapeShellArg cfg.default.dark}
          WALLPAPER_SOURCE=${lib.escapeShellArg config.preferences.theme.source}
          TRANSITION_DURATION=${lib.escapeShellArg cfg.transitionDuration}
          THEME_MODE=${lib.escapeShellArg themeMode}
        ''
        + builtins.readFile ./set-wallpaper.sh;
    };
  in {
    options.preferences.wallpaper = {
      default = {
        light = lib.mkOption {
          type = lib.types.path;
          default = "${defaults}/${meta.light.file}";
          defaultText = lib.literalMD "the light image from `meta.json`";
          description = "Default wallpaper in light mode (unless one is pinned).";
        };
        dark = lib.mkOption {
          type = lib.types.path;
          default = "${defaults}/${meta.dark.file}";
          defaultText = lib.literalMD "the dark image from `meta.json`";
          description = "Default wallpaper in dark mode (unless one is pinned).";
        };
      };

      directory = lib.mkOption {
        type = lib.types.str;
        default = "${home}/Pictures/Wallpapers";
        description = "User wallpaper collection (favourites in ./favourites).";
      };

      transitionDuration = lib.mkOption {
        type = lib.types.str;
        default = "0.8";
        description = "awww fade duration in seconds.";
      };

      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = setWallpaper;
        defaultText = lib.literalMD "the `set-wallpaper` command";
        description = "The `set-wallpaper` command.";
      };
    };

    config = {
      preferences.theme.switchCommand = "${lib.getExe setWallpaper} --mode";

      environment.systemPackages = [setWallpaper];

      home-manager.users.${user} = hm: {
        services.awww.enable = true;

        # Same safety net as waybar: retry (a condition skip is never retried).
        systemd.user.services.awww = {
          Unit = {
            ConditionEnvironment = lib.mkForce [];
            StartLimitIntervalSec = 60;
            StartLimitBurst = 30;
          };
          Service.RestartSec = lib.mkForce 1;
        };

        systemd.user.services.wallpaper-restore = {
          Unit = {
            Description = "Restore the wallpaper (set-wallpaper --restore)";
            After = ["awww.service"];
            Wants = ["awww.service"];
            PartOf = [hm.config.wayland.systemd.target];
          };
          Service = {
            Type = "oneshot";
            ExecStart = "${lib.getExe setWallpaper} --restore";
          };
          Install.WantedBy = [hm.config.wayland.systemd.target];
        };

        # Collection dirs + seed the defaults once (with their sidecars).
        home.activation.wallpaperSeed = hm.lib.hm.dag.entryAfter ["writeBoundary"] ''
          dir=${lib.escapeShellArg cfg.directory}
          seeded="''${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper/seeded"
          run mkdir -p "$dir/favourites" "$(dirname "$seeded")"
          if [ -z "''${DRY_RUN:-}" ]; then
            touch "$seeded"
            for src in ${lib.escapeShellArg cfg.default.light} ${lib.escapeShellArg cfg.default.dark}; do
              name="$(basename "$src")"
              grep -qxF "$name" "$seeded" && continue
              [ -e "$dir/$name" ] || cp --no-preserve=mode,ownership "$src" "$dir/$name"
              if [ -e "$src.json" ] && [ ! -e "$dir/$name.json" ]; then
                cp --no-preserve=mode,ownership "$src.json" "$dir/$name.json"
              fi
              echo "$name" >> "$seeded"
            done
          fi
        '';
      };
    };
  };
}
