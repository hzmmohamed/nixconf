{...}: {
  flake.nixosModules.nodejs = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      nodejs
      pnpm
    ];
  };
}
