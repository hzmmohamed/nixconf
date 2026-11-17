# Noctalia theme: a custom palette generated from preferences.theme.palette
# (light/dark) with the shared accent. Light/dark follows darkman via the
# theme-mode reload hook (default.nix).
{...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
    pal = config.preferences.theme.palette;

    mkVariant = c: onAccent: {
      primary = c.lavender;
      on_primary = onAccent;
      secondary = c.blue;
      on_secondary = onAccent;
      tertiary = c.peach;
      on_tertiary = onAccent;
      error = c.red;
      on_error = onAccent;
      surface = c.base;
      on_surface = c.text;
      surface_container = c.surface0;
      on_surface_variant = c.subtext0;
      outline_variant = c.surface1;
      shadow = c.crust;
      hover = c.surface1;
      on_hover = c.text;
      terminal = {
        background = c.base;
        foreground = c.text;
        cursor = c.rosewater;
        cursor_text = c.base;
        selection_bg = c.surface2;
        selection_fg = c.text;
        normal = {
          black = c.surface1;
          red = c.red;
          green = c.green;
          yellow = c.yellow;
          blue = c.blue;
          magenta = c.pink;
          cyan = c.teal;
          white = c.subtext1;
        };
        bright = {
          black = c.surface2;
          red = c.red;
          green = c.green;
          yellow = c.yellow;
          blue = c.blue;
          magenta = c.pink;
          cyan = c.teal;
          white = c.subtext0;
        };
      };
    };
  in {
    config = lib.mkIf (config.preferences.desktopShell == "noctalia") {
      home-manager.users.${user}.programs.noctalia = {
        customPalettes.Nixconf = {
          version = 2;
          dark = mkVariant pal.dark pal.dark.onAccent;
          light = mkVariant pal.light pal.light.onAccent;
        };

        settings.theme = {
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
      };
    };
  };
}
