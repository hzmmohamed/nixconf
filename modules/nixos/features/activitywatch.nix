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
          aw-watcher-window.package = pkgs.aw-watcher-window;
        };
      };

      # Watchers need WAYLAND_DISPLAY / DISPLAY from the compositor session.
      # Sway exports these via systemctl --user import-environment on startup,
      # but the watcher units can start before that completes. Binding them to
      # sway-session.target ensures the env vars are available.
      xdg.desktopEntries.activitywatch-dashboard = {
        name = "ActivityWatch";
        comment = "Open ActivityWatch dashboard";
        exec = "xdg-open http://localhost:5600";
        icon = "activitywatch";
        categories = ["Utility"];
      };

      systemd.user.services.activitywatch-watcher-aw-watcher-afk.Unit = {
        After = ["sway-session-env-ready.target"];
        Requires = ["sway-session-env-ready.target"];
      };
      systemd.user.services.activitywatch-watcher-aw-watcher-window.Unit = {
        After = ["sway-session-env-ready.target"];
        Requires = ["sway-session-env-ready.target"];
      };
    };
  };
}
