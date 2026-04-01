{...}: {
  flake.nixosModules.obs = {pkgs, ...}: {
    environment.systemPackages = [pkgs.obs-studio];
  };
}
