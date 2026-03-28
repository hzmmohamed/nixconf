{inputs, ...}: {
  flake.nixosModules.extra_hjem = {config, ...}: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.home-manager.nixosModules.home-manager
      inputs.catppuccin.nixosModules.catppuccin
    ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      users.${user} = {
        imports = [inputs.catppuccin.homeModules.catppuccin];

        home = {
          username = user;
          homeDirectory = "/home/${user}";
          stateVersion = config.system.stateVersion;
        };
      };
    };
  };
}
