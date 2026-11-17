{
  # Vicinae extension: search, preview, apply and favourite openly-licensed
  # wallpapers (Openverse, Wikimedia picture of the day, NASA APOD) with their
  # attribution kept in `<file>.json` sidecars. Applying goes through the
  # wallpaper subsystem's `set-wallpaper FILE`; "Current Wallpaper Info" reads
  # `set-wallpaper --info`. Downloads land in ~/Pictures/Wallpapers/,
  # favourites in ~/Pictures/Wallpapers/favourites/.
  #
  # Built from the local source with the committed package-lock.json
  # (importNpmLock, so no npmDepsHash to maintain). Requires the `vicinae`
  # feature for programs.vicinae.
  flake.nixosModules.vicinae-wallpapers = {config, ...}: {
    home-manager.users.${config.preferences.user.name} = {config, ...}: {
      programs.vicinae.extensions = [
        (config.lib.vicinae.mkExtension {
          name = "wallpapers";
          src = ./vicinae/extensions/wallpapers;
        })
      ];
    };
  };
}
