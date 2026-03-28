{inputs, self, ...}: {
  flake.nixosModules.sops = {
    ...
  }: {
    imports = [
      inputs.sops-nix.nixosModules.sops
    ];

    sops.age.keyFile = "${self.user.home}/.config/sops/age/keys.txt";
  };
}
