# GTK: adw-gtk3 (GTK3, e.g. Thunar) + libadwaita (GTK4) recoloured from the
# palette through a generated gtk.css (@define-color overrides of the
# libadwaita named colours), so both toolkits match and follow light/dark.
# Icons: Papirus / Papirus-Dark with folders tinted to the accent.
{...}: {
  flake.nixosModules.gtk = {
    pkgs,
    lib,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    theme = config.preferences.theme;

    lightTheme = "adw-gtk3";
    darkTheme = "adw-gtk3-dark";

    # papirus-folders only knows named colours: map the palette's Catppuccin
    # accent name to the closest one (fallback: indigo ≈ lavender).
    papirusFolderColor =
      {
        lavender = "indigo";
        blue = "blue";
        sapphire = "cyan";
        sky = "cyan";
        teal = "teal";
        green = "green";
        yellow = "yellow";
        peach = "orange";
        maroon = "red";
        red = "red";
        mauve = "violet";
        pink = "pink";
        flamingo = "pink";
        rosewater = "palebrown";
      }.${
        theme.palette.light.accentName or "lavender"
      } or "indigo";
    iconPackage = pkgs.papirus-icon-theme.override {color = papirusFolderColor;};

    # libadwaita / adw-gtk3 named colours. Shades/borders are opaque palette
    # mixes, never alpha.
    mkGtkCss = p: ''
      @define-color accent_color ${p.accent};
      @define-color accent_bg_color ${p.accent};
      @define-color accent_fg_color ${p.onAccent};
      @define-color destructive_color ${p.red};
      @define-color destructive_bg_color ${p.red};
      @define-color destructive_fg_color ${p.surface};
      @define-color success_color ${p.green};
      @define-color success_bg_color ${p.green};
      @define-color success_fg_color ${p.surface};
      @define-color warning_color ${p.peach};
      @define-color warning_bg_color ${p.peach};
      @define-color warning_fg_color ${p.surface};
      @define-color error_color ${p.red};
      @define-color error_bg_color ${p.red};
      @define-color error_fg_color ${p.surface};

      @define-color window_bg_color ${p.surface};
      @define-color window_fg_color ${p.fg};
      @define-color view_bg_color ${p.surface};
      @define-color view_fg_color ${p.fg};
      @define-color headerbar_bg_color ${p.surfaceContainerLow};
      @define-color headerbar_fg_color ${p.fg};
      @define-color headerbar_border_color ${p.hairline};
      @define-color headerbar_backdrop_color ${p.surface};
      @define-color headerbar_shade_color ${p.hairlineSoft};
      @define-color headerbar_darker_shade_color ${p.hairline};
      @define-color sidebar_bg_color ${p.surfaceContainerLow};
      @define-color sidebar_fg_color ${p.fg};
      @define-color sidebar_backdrop_color ${p.surfaceContainerLow};
      @define-color sidebar_shade_color ${p.hairlineSoft};
      @define-color sidebar_border_color ${p.hairlineSoft};
      @define-color secondary_sidebar_bg_color ${p.surfaceContainerLow};
      @define-color secondary_sidebar_fg_color ${p.fg};
      @define-color secondary_sidebar_backdrop_color ${p.surfaceContainerLow};
      @define-color secondary_sidebar_shade_color ${p.hairlineSoft};
      @define-color secondary_sidebar_border_color ${p.hairlineSoft};
      @define-color card_bg_color ${p.surfaceContainerLow};
      @define-color card_fg_color ${p.fg};
      @define-color card_shade_color ${p.hairlineSoft};
      @define-color dialog_bg_color ${p.surface};
      @define-color dialog_fg_color ${p.fg};
      @define-color popover_bg_color ${p.surface};
      @define-color popover_fg_color ${p.fg};
      @define-color popover_shade_color ${p.hairlineSoft};
      @define-color thumbnail_bg_color ${p.surface};
      @define-color thumbnail_fg_color ${p.fg};
      @define-color shade_color ${p.hairlineSoft};
      @define-color scrollbar_outline_color ${p.hairlineSoft};

      /* GTK3 legacy selection names (Thunar & co.): selected items must use
         the dark on-accent text, not the normal foreground. */
      @define-color theme_selected_bg_color ${p.accent};
      @define-color theme_selected_fg_color ${p.onAccent};
      @define-color selected_bg_color ${p.accent};
      @define-color selected_fg_color ${p.onAccent};
      .view:selected, .view text:selected, iconview:selected,
      .view:selected:focus, treeview:selected, flowboxchild:selected {
        background-color: ${p.accent};
        color: ${p.onAccent};
      }
    '';

    importCss = ''
      @import url("file://${theme.stateDir}/current/gtk.css");
    '';
  in {
    programs.dconf = {
      enable = lib.mkDefault true;
      profiles.user.databases = [
        {
          lockAll = false;
          settings."org/gnome/desktop/interface" = {
            gtk-theme = lightTheme;
            icon-theme = "Papirus";
            color-scheme = "prefer-light";
            # libadwaita's own accent setting; the generated gtk.css overrides
            # the accent colours anyway. "blue" is closest to lavender.
            accent-color = "blue";
          };
        }
      ];
    };

    environment.systemPackages = [
      pkgs.adw-gtk3
      iconPackage
      pkgs.gtk3
      pkgs.gtk4
    ];

    # Switched by theme-mode (and re-applied after every activation).
    preferences.theme = {
      files."gtk.css" = mkGtkCss;
      dconf = {
        "/org/gnome/desktop/interface/color-scheme" = {
          light = "'prefer-light'";
          dark = "'prefer-dark'";
        };
        "/org/gnome/desktop/interface/gtk-theme" = {
          light = "'${lightTheme}'";
          dark = "'${darkTheme}'";
        };
        "/org/gnome/desktop/interface/icon-theme" = {
          light = "'Papirus'";
          dark = "'Papirus-Dark'";
        };
      };
    };

    home-manager.users.${user}.gtk = {
      enable = true;
      theme = {
        name = lightTheme;
        package = pkgs.adw-gtk3;
      };
      iconTheme = {
        name = "Papirus";
        package = iconPackage;
      };
      # libadwaita is not themed by name; it only gets the colour overrides.
      gtk4.theme = null;
      gtk3.extraCss = importCss;
      gtk4.extraCss = importCss;
    };
  };
}
