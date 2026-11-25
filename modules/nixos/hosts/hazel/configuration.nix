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
      self.nixosModules.photos-client
      self.nixosModules.untrusted-browser
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
      self.nixosModules.vault
      self.nixosModules.activitywatch
      self.nixosModules.kdeconnect
      self.nixosModules.shared-zotero
      self.nixosModules.gimp
      self.nixosModules.email
      self.nixosModules.adb
      self.nixosModules.design
      self.nixosModules.cad
      self.nixosModules.dictation

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
      self.nixosModules.cable-link
      self.nixosModules.remote-deploy
      self.nixosModules.wifi-home
      self.nixosModules.syncthing

      self.nixosModules.powersave
      self.nixosModules.battery-notify
      # Launcher "Server mode": lid closed keeps running (T3 from the phone).
      self.nixosModules.server-mode
      self.nixosModules.memory-guard

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

    # Swap behind zram; small, the disk is 256 GB.
    preferences.memoryGuard.swapfileSize = 8 * 1024;

    # Watch butternut's battery (café: it runs headless, hazel is the screen).
    preferences.batteryAlert.remotes = ["butternut"];

    # Trial of the wallpaper-reactive palette (matugen, Catppuccin fallback).
    preferences.theme.source = "wallpaper";

    # Opt-in apps (off by default in their feature modules).
    preferences.discord.officialClient.enable = true;
    preferences.office.obsidian.enable = true;
    preferences.office.element.enable = true;
    preferences.media.extraApps.enable = true;
    preferences.design.extraApps.enable = true;

    # Dictation (Mod4+d): butternut's GPU server when reachable (cable
    # first, then the tailnet), else Parakeet/Whisper on this CPU/iGPU.
    preferences.dictation.servers = ["http://butternut-cable:8178" "http://butternut:8178"];

    networking = {
      hostName = "hazel";
      networkmanager.enable = true;
    };

    # Onboard ethernet enp4s0 (a discrete PCIe NIC: Realtek RTL8111, driver
    # r8169, on the E14 Gen 2 Intel). A router gives DHCP (`lan`),
    # butternut on the other end gives the static cable link (10.42.0.2, no
    # gateway, internet stays on Wi-Fi). See features/cable-link.nix.
    preferences.cable.interface = "enp4s0";

    # Wi-Fi profiles beyond home (secrets: see features/wifi-home.nix).
    preferences.wifi = {
      hotspot.enable = true;
      office.enable = true;
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
      # SSH client config for the other hosts (port, user, cable preference
      # for `ssh butternut`) comes from the hosts registry (/etc/ssh/ssh_config).

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
