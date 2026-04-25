{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.hazel = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostHazel
    ];
  };

  flake.nixosModules.hostHazel = {
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
      self.nixosModules.telegram
      self.nixosModules.media
      self.nixosModules.obs
      self.nixosModules.office
      self.nixosModules.rbw
      self.nixosModules.activitywatch
      self.nixosModules.kdeconnect

      self.nixosModules.vscode
      self.nixosModules.docker
      self.nixosModules.nodejs
      self.nixosModules.k8s
      self.nixosModules.aws
      self.nixosModules.atuin
      self.nixosModules.zellij
      self.nixosModules.yazi
      self.nixosModules.gpg
      self.nixosModules.doas
      self.nixosModules.reticulum

      self.nixosModules.tailscale
      self.nixosModules.sops
      self.nixosModules.wifi-home
      self.nixosModules.syncthing

      self.nixosModules.powersave
      self.nixosModules.battery-notify

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostHazel
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.systemd-boot.editor = false;
      loader.systemd-boot.consoleMode = "auto";
      loader.efi.canTouchEfiVariables = true;

      kernelParams = ["quiet"];
    };

    boot.plymouth.enable = true;

    time.timeZone = "Africa/Cairo";

    preferences.bibata-cursor.enable = true;

    networking = {
      hostName = "hazel";
      networkmanager.enable = true;
    };

    hardware.cpu.intel.updateMicrocode = true;
    hardware.graphics.enable = true;

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
    };

    programs.nix-ld.enable = true;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${lib.getExe pkgs.tuigreet} --time --remember-session --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };

    # Host-specific sway keybindings
    home-manager.users.${config.preferences.user.name}.wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
      "Mod4+v" = "exec ${lib.getExe pkgs.foot} --app-id clipse -e clipse";
      "Mod4+Shift+t" = "exec ${lib.getExe pkgs.darkman} toggle";
      "Mod4+period" = "exec wofi-emoji";
    };

    system.stateVersion = "25.05";
  };
}
