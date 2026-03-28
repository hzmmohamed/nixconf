{self, ...}: {
  # Niri + Noctalia desktop environment.
  # Can coexist with the sway module — greetd shows both as session options.
  flake.nixosModules.niri-desktop = {
    config,
    lib,
    pkgs,
    ...
  }: let
    selfpkgs = self.packages.${pkgs.system};
  in {
    programs.niri.enable = true;

    preferences.autostart = [selfpkgs.noctalia-shell];

    environment.systemPackages = [
      selfpkgs.niri
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
