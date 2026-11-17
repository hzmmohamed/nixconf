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
      self.nixosModules.gammastep
      self.nixosModules.waybar
      self.nixosModules.darkman
      self.nixosModules.btop
      self.nixosModules.swaync
      self.nixosModules.blueman
      self.nixosModules.vicinae
      self.nixosModules.vicinae-wallpapers
      self.nixosModules.mime-defaults
      self.nixosModules.bibata-cursor
      self.nixosModules.qt

      self.nixosModules.discord
      self.nixosModules.telegram
      self.nixosModules.media
      self.nixosModules.obs
      self.nixosModules.office
      self.nixosModules.rbw
      self.nixosModules.activitywatch
      self.nixosModules.kdeconnect
      self.nixosModules.shared-zotero
      self.nixosModules.gimp
      self.nixosModules.email
      self.nixosModules.adb
      self.nixosModules.design
      self.nixosModules.cad

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
      self.nixosModules.openssh
      self.nixosModules.lan-discovery
      self.nixosModules.lan-cache
      self.nixosModules.remote-deploy
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

    # Trial of the wallpaper-reactive palette (matugen, Catppuccin fallback).
    preferences.theme.source = "wallpaper";

    # Opt-in apps (off by default in their feature modules).
    preferences.discord.officialClient.enable = true;
    preferences.office.obsidian.enable = true;
    preferences.office.element.enable = true;
    preferences.media.extraApps.enable = true;
    preferences.design.extraApps.enable = true;

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
    };

    programs.nix-ld.enable = true;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${lib.getExe pkgs.tuigreet} --time --remember-session --sessions /run/current-system/sw/share/wayland-sessions";
        user = "greeter";
      };
    };

    home-manager.users.${config.preferences.user.name} = {
      # SSH client config for reaching other hosts over Tailscale
      programs.ssh = {
        enable = true;
        matchBlocks = {
          "butternut" = {
            hostname = "butternut";
            port = 7654;
            user = config.preferences.user.name;
          };
          "peacelily" = {
            hostname = "peacelily";
            port = 7654;
            user = config.preferences.user.name;
          };
          "maple" = {
            hostname = "maple";
            port = 7654;
            user = config.preferences.user.name;
          };
        };
      };

      # 14" 1080p built-in panel — slight scale bump for readability
      wayland.windowManager.sway.config.output."eDP-1" = {
        scale = "1.25";
      };

      # Host-specific sway keybindings
      wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
        "Mod4+v" = "exec vicinae deeplink 'vicinae://launch/clipboard/history?toggle=true'";
        "Mod4+Shift+t" = "exec ${lib.getExe pkgs.darkman} toggle";
        "Mod4+period" = "exec vicinae deeplink 'vicinae://launch/core/search-emojis?toggle=true'";
      };
    };

    system.stateVersion = "25.05";
  };
}
