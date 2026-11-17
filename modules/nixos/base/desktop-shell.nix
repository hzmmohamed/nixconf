{
  flake.nixosModules.base = {lib, ...}: {
    options.preferences.desktopShell = lib.mkOption {
      type = lib.types.enum ["waybar" "noctalia"];
      default = "waybar";
      description = ''
        Desktop shell layer on Sway hosts.
        - "waybar": composed stack (waybar + swaync + separate tools).
        - "noctalia": Noctalia v5 owns the bar, notifications and OSD.
        Feature modules gate themselves on this value; hosts may import both.
      '';
    };
  };
}
