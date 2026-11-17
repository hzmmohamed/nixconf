{
  inputs,
  self,
  ...
}: {
  flake.nixosModules.sops = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    imports = [
      inputs.sops-nix.nixosModules.sops
    ];

    sops.age.keyFile = "${self.user.home}/.config/sops/age/keys.txt";

    # Primary user's password hash from sops (see preferences.user.passwordFromSops).
    # Create it with: mkpasswd -m yescrypt | sops secrets/shared/user.yaml
    # (key `user-hashed-password`), then `git add` the file.
    sops.secrets."user-hashed-password" = lib.mkIf config.preferences.user.passwordFromSops {
      sopsFile = ../../.. + "/secrets/shared/user.yaml";
      neededForUsers = true;
    };

    users.users.${user} = lib.mkIf config.preferences.user.passwordFromSops {
      hashedPasswordFile = config.sops.secrets."user-hashed-password".path;
    };
  };
}
