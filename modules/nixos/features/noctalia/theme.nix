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

    mkVariant = c: {
      primary = c.accent;
      on_primary = c.onAccent;
      secondary = c.blue;
      on_secondary = c.onAccent;
      tertiary = c.peach;
      on_tertiary = c.onAccent;
      inherit (c) error surface;
      on_error = c.onAccent;
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
        cursor = c.rosewater;
        cursor_text = c.surface;
        selection_bg = c.surface2;
        selection_fg = c.fg;
        normal = {
          black = c.surface1;
          inherit (c) red green yellow blue;
          magenta = c.pink;
          cyan = c.teal;
          white = c.subtext1;
        };
        bright = {
          black = c.surface2;
          inherit (c) red green yellow blue;
          magenta = c.pink;
          cyan = c.teal;
          white = c.subtext0;
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
