{...}: {
  flake.nixosModules.activitywatch = {
    config,
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

      systemd.user.services.activitywatch-watcher-aw-watcher-afk.Unit = {
        After = ["sway-session.target"];
        Requires = ["sway-session.target"];
      };
    };
  };
}
