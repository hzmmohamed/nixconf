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
    appletEnabled = config.preferences.desktopShell == "waybar";
  in {
    services.blueman.enable = true;

    home-manager.users.${user} = {
      services.blueman-applet.enable = appletEnabled;
      services.network-manager-applet.enable = true;

      # These applets need a running Wayland display. Wait for sway-session.target
      # which fires after sway imports WAYLAND_DISPLAY into the user environment.
      systemd.user.services.blueman-applet.Unit = lib.mkIf appletEnabled {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };
      systemd.user.services.network-manager-applet.Unit = {
        After = ["sway-session.target"];
        Requisite = ["sway-session.target"];
      };
    };

    persistance.cache.directories = [
      ".local/share/blueman"
    ];
  };
}
