{...}: {
  flake.nixosModules.zellij = {pkgs, ...}: {
    environment.systemPackages = [pkgs.zellij];
  };
}
