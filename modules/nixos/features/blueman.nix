{...}: {
  flake.nixosModules.blueman = {config, ...}: let
    user = config.preferences.user.name;
  in {
    services.blueman.enable = true;

    home-manager.users.${user} = {
      services.blueman-applet.enable = true;
      services.network-manager-applet.enable = true;

      # These applets need a running Wayland display. Wait for sway-session.target
      # which fires after sway imports WAYLAND_DISPLAY into the user environment.
      systemd.user.services.blueman-applet.Unit = {
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
