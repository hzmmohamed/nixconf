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

  flake.nixosModules.hostButternut = {
    config,
    pkgs,
    lib,
    ...
  }: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.sway
      self.nixosModules.swayidle
      self.nixosModules.cliphist
      self.nixosModules.gammastep
      self.nixosModules.waybar

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.telegram

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
      self.nixosModules.ai
      self.nixosModules.music
      self.nixosModules.doas

      self.nixosModules.sops
      self.nixosModules.wifi-home
      self.nixosModules.syncthing

      self.nixosModules.powersave

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostButternut
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.systemd-boot.editor = false;
      loader.systemd-boot.consoleMode = "auto";
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

      asusd.enable = true;

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

    networking.firewall.allowedTCPPorts = [2222];

    programs.nix-ld.enable = true;
    programs.wayvnc.enable = true;

    # Cliphist keybinding for sway
    home-manager.users.${config.preferences.user.name}.wayland.windowManager.sway.config.keybindings = {
      "Mod4+v" = "exec cliphist list | wofi -S dmenu | cliphist decode | wl-copy";
    };

    hardware.graphics.enable = true;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${lib.getExe pkgs.tuigreet} --time --remember-session --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };

    system.stateVersion = "23.05";
  };
}
