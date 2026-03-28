{...}: {
  flake.nixosModules.doas = {config, ...}: let
    user = config.preferences.user.name;
  in {
    security.sudo.enable = false;
    security.doas = {
      enable = true;
      extraRules = [
        {
          users = [user];
          noPass = true;
          keepEnv = true;
        }
      ];
    };

    environment.shellAliases.sudo = "doas";
  };
}
