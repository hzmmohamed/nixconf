{...}: {
  flake.nixosModules.design = {
    pkgs,
    ...
  }: {
    environment.systemPackages = with pkgs; [
      inkscape
      blender
      fontforge
      font-manager
    ];
  };
}
