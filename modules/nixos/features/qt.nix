# Qt: qt6ct platform theme + Fusion style with a colour scheme generated from
# the palette (QGIS and other Qt6 apps match GTK and follow light/dark on
# their next start).
#
# ~/.config/qt6ct/qt6ct.conf links to the current mode's file: besides the
# colour-scheme path it carries the mode's icon theme (Papirus/Papirus-Dark),
# which qt6ct has no other way to switch.
{self, ...}: {
  flake.nixosModules.qt = {
    config,
    lib,
    pkgs,
    ...
  }: let
    theme = config.preferences.theme;

    # QPalette::ColorRole order as read by qt6ct.
    roles = p: [
      p.fg # WindowText
      p.surfaceContainer # Button
      p.surface1 # Light
      p.surface0 # Midlight
      p.crust # Dark
      p.surface2 # Mid
      p.fg # Text
      p.surface # BrightText
      p.fg # ButtonText
      p.surface # Base
      p.surfaceContainerLow # Window
      p.crust # Shadow
      p.inverseSurface # Highlight (emphasis by inversion)
      p.onInverseSurface # HighlightedText
      p.accent # Link
      p.mauve # LinkVisited
      p.surfaceContainerLow # AlternateBase
      p.surface # NoRole
      p.surface # ToolTipBase
      p.fg # ToolTipText
      p.fgFaint # PlaceholderText
      p.accent # Accent
    ];
    disabled = p:
      lib.imap0 (i: c:
        if lib.elem i [0 6 8]
        then p.fgFaint
        else c) (roles p);

    mkColorScheme = p: ''
      [ColorScheme]
      active_colors=${lib.concatStringsSep ", " (roles p)}
      inactive_colors=${lib.concatStringsSep ", " (roles p)}
      disabled_colors=${lib.concatStringsSep ", " (disabled p)}
    '';

    mkQt6ctConf = p: ''
      [Appearance]
      color_scheme_path=${theme.stateDir}/current/qt6ct-colors.conf
      custom_palette=true
      icon_theme=${
        if p.isDark
        then "Papirus-Dark"
        else "Papirus"
      }
      standard_dialogs=default
      style=Fusion

      [Fonts]
      fixed="${self.fonts.monospace},${toString self.fonts.size},-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
      general="${self.fonts.sansSerif},${toString self.fonts.size},-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    '';
  in {
    # qt.enable wires QT_PLUGIN_PATH for the system profile; the qt5ct
    # platform installs both qt5ct and qt6ct, but Qt6 apps (QGIS) need the
    # "qt6ct" key.
    qt = {
      enable = true;
      platformTheme = "qt5ct";
    };
    environment.variables.QT_QPA_PLATFORMTHEME = lib.mkForce "qt6ct";
    environment.sessionVariables.QT_QPA_PLATFORMTHEME = "qt6ct";

    preferences.theme = {
      files."qt6ct-colors.conf" = mkColorScheme;
      files."qt6ct.conf" = mkQt6ctConf;
      links.".config/qt6ct/qt6ct.conf" = "qt6ct.conf";
    };

    environment.systemPackages = [pkgs.qt6Packages.qt6ct];
  };
}
