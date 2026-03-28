{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.butternut = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostButternut
    ];
  };

  flake.nixosModules.hostButternut = {pkgs, ...}: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.hyprland
      self.nixosModules.telegram
      self.nixosModules.youtube-music

      self.nixosModules.powersave

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostButternut
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.efi.canTouchEfiVariables = true;

      kernelParams = ["quiet" "i915.force_probe=46a6"];
      kernelModules = ["kvm-intel"];
    };

    boot.plymouth.enable = true;

    networking = {
      hostName = "butternut";
      networkmanager.enable = true;
    };

    hardware.cpu.intel.updateMicrocode = true;

    services = {
      flatpak.enable = true;
      udisks2.enable = true;
      printing.enable = true;

      asusd = {
        enable = true;
        enableUserService = true;
      };

      openssh = {
        enable = true;
        ports = [7654];
        settings = {
          PasswordAuthentication = true;
          KbdInteractiveAuthentication = true;
          PermitRootLogin = "no";
        };
      };
    };

    networking.firewall.allowedTCPPorts = [2222];

    programs.niri.enable = true;
    programs.nix-ld.enable = true;
    programs.wayvnc.enable = true;

    xdg.portal.extraPortals = [pkgs.xdg-desktop-portal-gtk];
    xdg.portal.enable = true;

    hardware.graphics.enable = true;

    system.stateVersion = "23.05";
  };
}
