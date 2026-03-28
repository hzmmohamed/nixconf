{...}: {
  flake.nixosModules.office = {
    pkgs,
    ...
  }: {
    environment.systemPackages = with pkgs; [
      obsidian
      libreoffice
      typst
      element-desktop
      zathura
      pdfgrep
    ];
  };
}
