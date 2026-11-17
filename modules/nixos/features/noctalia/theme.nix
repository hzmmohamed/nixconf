# Noctalia theme: the shared palette (preferences.theme.palette shape) as a
# Noctalia custom palette, with Noctalia's own wallpaper/templates disabled.
#
# - Catppuccin source: `customPalettes.Nixconf` from the build-time palette;
#   light/dark follows darkman via the theme-mode reload hook (default.nix).
# - Wallpaper source: the same variant renderer is registered as a theme file
#   (noctalia-palette.json), so it is rendered through the shared template
#   path — Catppuccin at build time, matugen at runtime — and
#   ~/.config/noctalia/palettes/Nixconf.json links to the current mode's file.
#   Each per-mode file carries that mode's colours in both variants; the reload
#   hook re-reads it with `noctalia msg config-reload` (which re-resolves the
#   custom palette from disk).
{...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
    theme = config.preferences.theme;
    pal = theme.palette;
    enabled = config.preferences.desktopShell == "noctalia";
    wallpaperSource = theme.source == "wallpaper";
    noctalia = config.home-manager.users.${user}.programs.noctalia.package;

    # Noctalia fills primary/secondary/tertiary with text on them: the
    # selection fill (≥4.5:1 with its on-colour) and the status roles.
    mkVariant = c: {
      primary = c.selection;
      on_primary = c.onSelection;
      secondary = c.info;
      on_secondary = c.onInfo;
      tertiary = c.warning;
      on_tertiary = c.onWarning;
      inherit (c) error surface;
      on_error = c.onError;
      on_surface = c.onSurface;
      surface_container = c.surfaceContainer;
      on_surface_variant = c.onSurfaceVariant;
      outline_variant = c.outlineVariant;
      shadow = c.crust;
      hover = c.surfaceContainerHigh;
      on_hover = c.onSurface;
      terminal = {
        background = c.surface;
        foreground = c.fg;
        cursor = c.selection;
        cursor_text = c.onSelection;
        selection_bg = c.inverseSurface;
        selection_fg = c.onInverseSurface;
        normal = {
          black = c.surfaceContainerHigh;
          red = c.ansiRed;
          green = c.ansiGreen;
          yellow = c.ansiYellow;
          blue = c.ansiBlue;
          magenta = c.ansiMagenta;
          cyan = c.ansiCyan;
          white = c.fgDim;
        };
        bright = {
          black = c.surfaceContainerHighest;
          red = c.ansiRed;
          green = c.ansiGreen;
          yellow = c.ansiYellow;
          blue = c.ansiBlue;
          magenta = c.ansiMagenta;
          cyan = c.ansiCyan;
          white = c.fg;
        };
      };
    };
  in {
    config = lib.mkIf enabled (lib.mkMerge [
      {
        home-manager.users.${user}.programs.noctalia.settings.theme = {
          source = "custom";
          custom_palette = "Nixconf";
          # Initial value only: darkman sets the live mode over IPC.
          mode = "light";
          pure_black_dark = false;
          # Don't let Noctalia rewrite other apps' themes; darkman owns that.
          templates = {
            enable_builtin_templates = false;
            enable_community_templates = false;
          };
        };
      }

      (lib.mkIf (!wallpaperSource) {
        home-manager.users.${user}.programs.noctalia.customPalettes.Nixconf = {
          version = 2;
          dark = mkVariant pal.dark;
          light = mkVariant pal.light;
        };
      })

      (lib.mkIf wallpaperSource {
        preferences.theme = {
          files."noctalia-palette.json" = p:
            builtins.toJSON {
              version = 2;
              dark = mkVariant p;
              light = mkVariant p;
            };
          links.".config/noctalia/palettes/Nixconf.json" = "noctalia-palette.json";
          # Runs after the mode hook in default.nix (attribute order).
          reloadHooks.noctalia-palette = ''
            ${lib.getExe noctalia} msg config-reload >/dev/null 2>&1 || true
          '';
        };
      })
    ]);
  };
}
