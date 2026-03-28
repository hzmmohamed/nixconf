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
    programs.niri.package = selfpkgs.niri;

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

    # The upstream niri.service runs the unwrapped binary;
    # set NIRI_CONFIG so it picks up our wrapped config
    # (keybinds, spawn-at-startup for noctalia/wallpaper, etc.)
    systemd.user.services.niri.serviceConfig.Environment = let
      wrapperScript = builtins.readFile "${selfpkgs.niri}/bin/niri";
      configPath = builtins.head (builtins.match ".*NIRI_CONFIG ([^\n]+)\n.*" wrapperScript);
    in ["NIRI_CONFIG=${configPath}"];

    systemd.user.services.noctalia-shell = {
      description = "Noctalia Shell";
      partOf = ["graphical-session.target"];
      after = ["niri.service"];
      wantedBy = ["graphical-session.target"];
      serviceConfig = {
        ExecStart = lib.getExe selfpkgs.noctalia-shell;
        Restart = "always";
        RestartSec = 2;
      };
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
