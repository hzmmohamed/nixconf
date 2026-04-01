{...}: {
  flake.nixosModules.openrgb = {pkgs, ...}: {
    services.hardware.openrgb.enable = true;

    environment.systemPackages = [pkgs.openrgb];
  };
}
