# Sway workspace auto-placement (part of the `sway` module — same
# flake.nixosModules.sway, split into its own file).
#
#   1 terminal (never assigned: opens wherever you are)
#   2 files + office   3 audio   4 browsers   5 code editors   6 QGIS   7-9 free
#
# Only `assign` rules: the window is created on its workspace without switching
# focus there. Matching is on Wayland app_id only (no titles/roles), so dialogs
# of these apps follow their parent app — and nothing else is affected.
# Regexes are case-insensitive and avoid backslashes (`.` matches any char).
{
  flake.nixosModules.sway = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
    appIds = ids: map (id: {app_id = "(?i)^(${id})$";}) ids;
  in {
    options.preferences.sway.workspaceAssignments = lib.mkEnableOption ''
      automatic placement of apps on fixed Sway workspaces (2 files/office,
      3 audio, 4 browsers, 5 editors, 6 QGIS)
    '';

    config = lib.mkIf config.preferences.sway.workspaceAssignments {
      home-manager.users.${user}.wayland.windowManager.sway.config.assigns = {
        "number 2" = appIds [
          "thunar|org.xfce.thunar" # Thunar
          "libreoffice-.*|soffice" # LibreOffice (writer, calc, impress, startcenter…)
          "chrome-.*.ts.net__photos-.*" # Immich app window (photos-open)
        ];
        "number 3" = appIds [
          "com.saivert.pwvucontrol" # pwvucontrol
          "pavucontrol|org.pulseaudio.pavucontrol" # pavucontrol (gtk3 / gtk4 ids)
          "org.rncbc.qpwgraph" # qpwgraph
        ];
        "number 4" = appIds [
          "firefox"
          "chromium-browser|chromium" # PWAs use chrome-<id>-* and are not matched
        ];
        "number 5" = appIds [
          "codium|vscodium" # VSCodium
          "dev.zed.zed" # Zed
          "chrome-.*.ts.net__-.*" # T3 Code / OpenCode app windows (t3-open; root URL only)
        ];
        "number 6" = appIds [
          "org.qgis.qgis|qgis.*" # QGIS (4.x: org.qgis.qgis)
        ];
      };
    };
  };
}
