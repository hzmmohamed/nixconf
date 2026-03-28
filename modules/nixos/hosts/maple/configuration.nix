{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.maple = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostMaple
    ];
  };

  flake.nixosModules.hostMaple = {pkgs, lib, ...}: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      # Switch between WMs by changing this one line:
      # self.nixosModules.sway        # Sway + waybar (Catppuccin)
      self.nixosModules.niri-desktop   # Niri + Noctalia (Gruvbox)

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.telegram
      self.nixosModules.youtube-music

      self.nixosModules.rbw
      self.nixosModules.office
      self.nixosModules.docker
      self.nixosModules.media
      self.nixosModules.adb
      self.nixosModules.tailscale
      self.nixosModules.vscode
      self.nixosModules.k8s
      self.nixosModules.aws
      self.nixosModules.atuin
      self.nixosModules.zellij
      self.nixosModules.yazi
      self.nixosModules.design
      self.nixosModules.shared-zotero
      self.nixosModules.gpg
      self.nixosModules.nodejs
      self.nixosModules.cad
      self.nixosModules.doas

      self.nixosModules.sops
      self.nixosModules.syncthing

      self.nixosModules.powersave

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostMaple
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.efi.canTouchEfiVariables = true;

      kernelParams = ["quiet"];
    };

    boot.plymouth.enable = true;

    networking = {
      hostName = "maple";
      networkmanager.enable = true;
    };

    hardware.cpu.intel.updateMicrocode = true;

    services = {
      flatpak.enable = true;
      udisks2.enable = true;
      printing.enable = true;

      openssh = {
        enable = true;
        ports = [7654];
        settings = {
          PasswordAuthentication = true;
          KbdInteractiveAuthentication = true;
          PermitRootLogin = "no";
        };
      };

      nix-serve = {
        enable = true;
        package = pkgs.nix-serve-ng;
        openFirewall = true;
      };
    };

    programs.nix-ld.enable = true;

    hardware.graphics.enable = true;

    time.timeZone = "Africa/Cairo";

    system.stateVersion = "24.11";
  };
}
