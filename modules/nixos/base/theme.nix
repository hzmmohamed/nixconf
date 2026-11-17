# Theme options: one palette shape for every themed module, plus the
# registration points for the unified light/dark switch (implemented by
# extra/theme.nix, driven by darkman through `theme-mode light|dark`).
#
# Modules never read hex values themselves: they take colours from
# config.preferences.theme.palette.{light,dark} (shape: see modules/theme.nix
# mkPalette) and register *palette-only* files that their app includes from
# ${stateDir}/current/.
{self, ...}: {
  flake.nixosModules.base = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.theme;
    user = config.preferences.user.name;

    perMode = lib.types.submodule {
      options = {
        light = lib.mkOption {type = lib.types.str;};
        dark = lib.mkOption {type = lib.types.str;};
      };
    };
  in {
    options.preferences.theme = {
      source = lib.mkOption {
        type = lib.types.enum ["catppuccin" "wallpaper"];
        default = "catppuccin";
        description = ''
          Where the palette comes from.
          - "catppuccin": Latte (light) / Mocha (dark), lavender accent.
          - "wallpaper": generated at runtime from the current wallpaper
            (matugen, `theme-mode generate`, see extra/theme.nix). The
            build-time palette below stays Catppuccin: it renders the
            fallback files and fills any key the generator can't provide.
        '';
      };

      palette = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        readOnly = true;
        default =
          {
            catppuccin = self.palettes.catppuccin;
            # Runtime palette comes from matugen; this is its fallback layer.
            wallpaper = self.palettes.catppuccin;
          }.${
            cfg.source
          };
        defaultText = lib.literalExpression "self.palettes.catppuccin";
        description = "Build-time palettes `{ light, dark }` (read-only).";
      };

      stateDir = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${config.users.users.${user}.home}/.local/state/theme";
        description = ''
          Runtime theme state: `light/` and `dark/` hold the per-app palette
          files, `current` is a symlink to one of them.
        '';
      };

      files = lib.mkOption {
        type = lib.types.attrsOf (lib.types.functionTo lib.types.lines);
        default = {};
        example = lib.literalExpression ''{ "kitty.conf" = p: "background ''${p.base}"; }'';
        description = ''
          Palette-only files, keyed by file name. Each value renders a palette
          to text; it is rendered once per mode into
          ''${stateDir}/{light,dark}/<name>. Apps include
          ''${stateDir}/current/<name>.
        '';
      };

      links = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
        example = {".config/wofi/style.css" = "wofi.css";};
        description = ''
          Home-relative paths symlinked to ''${stateDir}/current/<file>, for
          apps that can't include a file from an arbitrary path.
        '';
      };

      reloadHooks = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = {};
        description = ''
          Shell snippets run by `theme-mode` after `current` was flipped
          (`$mode` is "light" or "dark"). Failures are ignored.
        '';
      };

      switchCommand = lib.mkOption {
        type = lib.types.str;
        description = ''
          Command darkman runs with `light` or `dark` appended. Defaults to
          `theme-mode`; the wallpaper feature sets it to
          `set-wallpaper --mode`, which also swaps to the paired default
          wallpaper (and, for the wallpaper source, regenerates the palette)
          before calling `theme-mode`.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        internal = true;
        description = "The `theme-mode` command (set by extra/theme.nix).";
      };

      dconf = lib.mkOption {
        type = lib.types.attrsOf perMode;
        default = {};
        example = {
          "/org/gnome/desktop/interface/gtk-theme" = {
            light = "'adw-gtk3'";
            dark = "'adw-gtk3-dark'";
          };
        };
        description = ''
          dconf keys written by `theme-mode` (and re-applied on activation,
          after home-manager's own dconf step).
        '';
      };
    };
  };
}
