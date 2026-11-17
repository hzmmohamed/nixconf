{...}: {
  flake.nixosModules.blueman = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
    # Only one BlueZ pairing agent should run: in "noctalia" mode Noctalia's
    # control center registers its own, so the blueman tray applet stays off.
    # (blueman-manager remains available either way.)
    waybarShell = config.preferences.desktopShell == "waybar";
    appletEnabled = waybarShell;
  in {
    services.blueman.enable = true;

    home-manager.users.${user} = {
      services.blueman-applet.enable = appletEnabled;
      # In "waybar" mode the bar's network module replaces nm-applet's tray
      # icon (nmtui / nm-connection-editor from its click actions).
      services.network-manager-applet.enable = !waybarShell;

      # blueman-applet stays for its pairing agent, but its tray icon would
      # duplicate the waybar bluetooth module: unload the StatusIcon plugin
      # (and ShowConnected, which would pull it back in as a dependency).
      dconf.settings = lib.mkIf appletEnabled {
        "org/blueman/general".plugin-list = ["!StatusIcon" "!ShowConnected"];
      };

      # These applets need a running Wayland display. Wait for sway-session.target
      # which fires after sway imports WAYLAND_DISPLAY into the user environment.
      systemd.user.services.blueman-applet.Unit = lib.mkIf appletEnabled {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };
      systemd.user.services.network-manager-applet.Unit = lib.mkIf (!waybarShell) {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };
    };

    persistance.cache.directories = [
      ".local/share/blueman"
    ];
  };
}
