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
    };
  };
}
