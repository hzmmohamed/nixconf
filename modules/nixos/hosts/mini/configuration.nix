{
  inputs,
  self,
  lib,
  ...
}: {
  flake.nixosConfigurations.mini = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostMini
    ];
  };

  flake.nixosModules.hostMini = {pkgs, ...}: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.hyprland
      self.nixosModules.telegram
      self.nixosModules.youtube-music

      self.nixosModules.gaming

      self.nixosModules.powersave
    ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    networking.hostName = "mini";

    networking.networkmanager.enable = true;

    programs.niri.enable = true;
    programs.niri.package = self.packages.${pkgs.system}.niri;
    preferences.autostart = [self.packages.${pkgs.system}.noctalia-shell];
    environment.systemPackages = [self.packages.${pkgs.system}.noctalia-shell];

    time.timeZone = "Europe/Kyiv";
    i18n.extraLocaleSettings = {
      LC_ADDRESS = "uk_UA.UTF-8";
      LC_IDENTIFICATION = "uk_UA.UTF-8";
      LC_MEASUREMENT = "uk_UA.UTF-8";
      LC_MONETARY = "uk_UA.UTF-8";
      LC_NAME = "uk_UA.UTF-8";
      LC_NUMERIC = "uk_UA.UTF-8";
      LC_PAPER = "uk_UA.UTF-8";
      LC_TELEPHONE = "uk_UA.UTF-8";
      LC_TIME = "uk_UA.UTF-8";
    };

    boot.kernelPackages = pkgs.linuxPackages_latest;

    system.stateVersion = "25.11";
  };
}
