{
  inputs,
  self,
  ...
}: {
  flake.nixosModules.reticulum = {pkgs, ...}: {
    imports = [
      inputs.reticulum-flake.nixosModules.reticulum-shared
      inputs.reticulum-flake.nixosModules.reticulum-integration
      inputs.reticulum-flake.nixosModules.meshchat-launchers
    ];

    nixpkgs.overlays = [inputs.reticulum-flake.overlays.default];

    environment.systemPackages = [
      self.packages.${pkgs.system}.meshchatx
      self.packages.${pkgs.system}.meshchatx-desktop-entry
    ];
  };
}
