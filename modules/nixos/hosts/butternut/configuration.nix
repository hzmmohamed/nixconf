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
      self.nixosModules.clipse
      self.nixosModules.gammastep
      self.nixosModules.waybar
      self.nixosModules.darkman
      self.nixosModules.foot
      self.nixosModules.btop
      self.nixosModules.mako
      self.nixosModules.blueman
      self.nixosModules.wofi-emoji
      self.nixosModules.bibata-cursor

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.telegram
      self.nixosModules.obs

      self.nixosModules.email
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
      self.nixosModules.reticulum
      self.nixosModules.kdeconnect
      self.nixosModules.whisper-live
      self.nixosModules.openrgb
      self.nixosModules.activitywatch

      self.nixosModules.sops
      self.nixosModules.wifi-home
      self.nixosModules.syncthing

      self.nixosModules.powersave
      self.nixosModules.battery-notify

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

    time.timeZone = "Africa/Cairo";

    preferences.bibata-cursor.enable = true;

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
      vnstat.enable = true;

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

    # Host-specific sway keybindings
    home-manager.users.${config.preferences.user.name}.wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
      "Mod4+v" = "exec ${lib.getExe pkgs.foot} --app-id clipse -e clipse";
      "Mod4+Shift+t" = "exec ${lib.getExe pkgs.darkman} toggle";
      "Mod4+period" = "exec wofi-emoji";
      "Mod4+n" = "exec dnd-toggle";
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
