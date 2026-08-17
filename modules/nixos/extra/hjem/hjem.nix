{inputs, ...}: {
  flake.nixosModules.extra_hjem = {config, ...}: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.home-manager.nixosModules.home-manager
      inputs.catppuccin.nixosModules.catppuccin
    ];

    # catppuccin/nix is moving to `autoEnable`-driven port enrollment where
    # `catppuccin.enable` becomes a global toggle. Pin autoEnable to our current
    # `enable` value (false) so theming stays driven by explicit per-port options.
    catppuccin.autoEnable = false;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      backupFileExtension = "backup";

      users.${user} = {
        imports = [inputs.catppuccin.homeModules.catppuccin];

        catppuccin.autoEnable = false;

        home = {
          username = user;
          homeDirectory = "/home/${user}";
          stateVersion = config.system.stateVersion;
        };
      };
    };
  };
}
