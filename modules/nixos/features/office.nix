# Office/document tools. Obsidian and Element are opt-in per host:
#   preferences.office.obsidian.enable = true;
#   preferences.office.element.enable = true;
{...}: {
  flake.nixosModules.office = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.office;
  in {
    options.preferences.office = {
      obsidian.enable = lib.mkEnableOption "Obsidian";
      element.enable = lib.mkEnableOption "Element (Matrix) desktop client";
    };

    config.environment.systemPackages = with pkgs;
      [
        libreoffice
        typst
        zathura
        pdfgrep
      ]
      ++ lib.optional cfg.obsidian.enable obsidian
      ++ lib.optional cfg.element.enable element-desktop;
  };
}
