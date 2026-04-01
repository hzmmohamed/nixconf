{...}: {
  flake.nixosModules.openrgb = {
    services.hardware.openrgb.enable = true;

    environment.systemPackages = [pkgs.openrgb];
  };
}
