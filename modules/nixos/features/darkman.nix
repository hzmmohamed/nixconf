# darkman decides light vs dark (sunrise/sunset at a fixed location) and hands
# the switch to `theme-mode` (extra/theme.nix), which flips
# ~/.local/state/theme/current, writes the registered dconf keys and runs every
# module's reload hook. Per-app theming lives in the app's own module.
{...}: {
  flake.nixosModules.darkman = {
    lib,
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    themeMode = lib.getExe config.preferences.theme.package;
  in {
    home-manager.users.${user}.services.darkman = {
      enable = true;
      settings = {
        usegeoclue = false;
        lat = 30.0;
        lng = 31.2;
      };
      lightModeScripts.theme = "${themeMode} light";
      darkModeScripts.theme = "${themeMode} dark";
    };

    environment.systemPackages = [pkgs.darkman];
  };
}
