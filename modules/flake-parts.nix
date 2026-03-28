{inputs, ...}: {
  imports = [
    inputs.flake-parts.flakeModules.modules
    inputs.devenv.flakeModule
    inputs.treefmt-nix.flakeModule
  ];

  options = {
    flake = inputs.flake-parts.lib.mkSubmoduleOptions {
      wrapperModules = inputs.nixpkgs.lib.mkOption {
        default = {};
      };
      diskoConfigurations = inputs.nixpkgs.lib.mkOption {
        default = {};
      };
    };
  };

  config = {
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
