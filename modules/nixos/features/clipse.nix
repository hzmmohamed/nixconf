{...}: {
  flake.nixosModules.clipse = {config, ...}: let
    user = config.preferences.user.name;
  in {
    home-manager.users.${user}.services.clipse = {
      enable = true;
      systemdTarget = "sway-session.target";
    };
  };
}
