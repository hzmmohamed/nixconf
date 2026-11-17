# Keyboard layouts shared by every Sway host (consumed by sway.nix; the bar
# widgets show the active layout).
{
  flake.nixosModules.base = {lib, ...}: {
    options.preferences.keyboard = {
      layouts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["us" "ara"];
        description = "XKB layouts, in cycle order (first = default).";
      };
      toggle = lib.mkOption {
        type = lib.types.str;
        default = "grp:alt_shift_toggle";
        description = "XKB group-switch option used to cycle layouts.";
      };
      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["caps:escape"];
        description = "Further XKB options (merged with `toggle`).";
      };
    };
  };
}
