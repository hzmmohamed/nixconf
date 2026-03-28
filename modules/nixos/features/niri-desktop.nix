{self, ...}: {
  # Niri + Noctalia desktop environment.
  # Alternative to the sway module — hosts import one or the other.
  flake.nixosModules.niri-desktop = {
    config,
    lib,
    pkgs,
    ...
  }: let
    selfpkgs = self.packages.${pkgs.system};
  in {
    programs.niri.enable = true;
    programs.niri.package = selfpkgs.niri;

    preferences.autostart = [selfpkgs.noctalia-shell];

    environment.systemPackages = [
      selfpkgs.noctalia-shell
      pkgs.wl-clipboard
      pkgs.grim
      pkgs.slurp
      pkgs.networkmanagerapplet
    ];

    xdg.portal = {
      enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
    };

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      MOZ_ENABLE_WAYLAND = "1";
      XDG_SESSION_TYPE = "wayland";
      NIXOS_OZONE_WL = "1";
    };
  };
}
