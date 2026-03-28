# Bibata cursor theme — opt-in per host.
#
# This module uses an enable option rather than being activated by import.
# Most modules in this repo activate on import (e.g. sway, waybar), which
# is simpler but means every host that imports the module gets the feature.
# For user-preference features like cursors, an enable option lets hosts
# import the module (making the option available) without forcing it on:
#
#   imports = [ self.nixosModules.bibata-cursor ];  # defines the option
#   preferences.bibata-cursor.enable = true;        # host opts in
#
{...}: {
  flake.nixosModules.bibata-cursor = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.bibata-cursor;
    user = config.preferences.user.name;
  in {
    options.preferences.bibata-cursor = {
      enable = lib.mkEnableOption "Bibata Modern Classic cursor theme";
      size = lib.mkOption {
        type = lib.types.int;
        default = 17;
      };
    };

    config = lib.mkIf cfg.enable {
      home-manager.users.${user}.home.pointerCursor = {
        name = "Bibata-Modern-Classic";
        package = pkgs.bibata-cursors;
        size = cfg.size;
        gtk.enable = true;
      };

      environment.sessionVariables = {
        XCURSOR_THEME = "Bibata-Modern-Classic";
        XCURSOR_SIZE = toString cfg.size;
      };
    };
  };
}
