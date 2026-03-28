{...}: {
  flake.nixosModules.nodejs = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      nodejs
      nodePackages.npm
      nodePackages.pnpm
    ];
  };
}
