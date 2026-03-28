{...}: {
  flake.nixosModules.blueman = {config, ...}: let
    user = config.preferences.user.name;
  in {
    services.blueman.enable = true;

    home-manager.users.${user} = {
      services.blueman-applet.enable = true;
      services.network-manager-applet.enable = true;
    };

    persistance.cache.directories = [
      ".local/share/blueman"
    ];
  };
}
