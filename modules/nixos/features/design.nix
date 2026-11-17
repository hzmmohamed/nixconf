# Design tools. Inkscape is always installed; Blender, FontForge and
# font-manager are opt-in per host — otherwise run them on demand with
# comma (`, blender`) or pin Blender per project.
#   preferences.design.extraApps.enable = true;
{...}: {
  flake.nixosModules.design = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.preferences.design.extraApps.enable =
      lib.mkEnableOption "heavy design apps (Blender, FontForge, font-manager)";

    config.environment.systemPackages = with pkgs;
      [inkscape]
      ++ lib.optionals config.preferences.design.extraApps.enable [
        blender
        fontforge
        font-manager
      ];
  };
}
