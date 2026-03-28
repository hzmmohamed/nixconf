{inputs, ...}: {
  flake.nixosModules.extra_hjem = {config, ...}: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.home-manager.nixosModules.home-manager
    ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      users.${user} = {
        home = {
          username = user;
          homeDirectory = "/home/${user}";
          stateVersion = config.system.stateVersion;
        };
      };
    };
  };
}
