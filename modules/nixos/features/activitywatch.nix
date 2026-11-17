{...}: {
  flake.nixosModules.activitywatch = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    home-manager.users.${user} = {
      services.activitywatch = {
        enable = true;
        watchers = {
          aw-watcher-afk.package = pkgs.aw-watcher-afk;
          # aw-watcher-window is X11-only and crashes on Wayland.
          # Disabled until upstream adds Wayland support.
        };
      };

      xdg.desktopEntries.activitywatch-dashboard = {
        name = "ActivityWatch";
        comment = "Open ActivityWatch dashboard";
        exec = "xdg-open http://localhost:5600";
        icon = "activitywatch";
        categories = ["Utility"];
      };

      # Start with the sway session rather than pulling it in. A `Requires=` here
      # started sway-session.target (and graphical-session.target) at user-manager
      # startup, before sway exported WAYLAND_DISPLAY, so waybar was skipped.
      systemd.user.services.activitywatch-watcher-aw-watcher-afk = {
        Unit = {
          After = ["sway-session.target"];
          PartOf = ["sway-session.target"];
        };
        Install.WantedBy = lib.mkForce ["sway-session.target"];
      };
    };
  };
}
