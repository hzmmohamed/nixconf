# darkman decides light vs dark (sunrise/sunset at a fixed location) and hands
# the switch to preferences.theme.switchCommand — `theme-mode` (extra/theme.nix),
# or `set-wallpaper --mode` when the wallpaper feature is imported, which swaps
# the paired default wallpaper first. theme-mode flips
# ~/.local/state/theme/current, writes the registered dconf keys and runs every
# module's reload hook. Per-app theming lives in the app's own module.
{...}: {
  flake.nixosModules.darkman = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    switch = config.preferences.theme.switchCommand;
  in {
    home-manager.users.${user}.services.darkman = {
      enable = true;
      settings = {
        usegeoclue = false;
        lat = 30.0;
        lng = 31.2;
      };
      lightModeScripts.theme = "${switch} light";
      darkModeScripts.theme = "${switch} dark";
    };

    environment.systemPackages = [pkgs.darkman];
  };
}
