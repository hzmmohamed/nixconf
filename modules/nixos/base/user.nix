{self, ...}: {
  flake.nixosModules.base = {lib, ...}: {
    options.preferences = {
      user.name = lib.mkOption {
        type = lib.types.str;
        default = self.user.name;
      };

      user.passwordFromSops = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Take the primary user's password hash from the sops secret
          `user-hashed-password` in secrets/shared/user.yaml instead of the
          hash committed in the `general` feature. Implemented by the `sops`
          feature, so it only has an effect on hosts that import it.
        '';
      };
    };
  };
}
