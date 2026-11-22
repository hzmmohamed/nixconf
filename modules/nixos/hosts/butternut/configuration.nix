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
      self.nixosModules.gammastep
      self.nixosModules.waybar
      self.nixosModules.darkman
      self.nixosModules.btop
      self.nixosModules.swaync
      self.nixosModules.noctalia
      self.nixosModules.blueman
      self.nixosModules.vicinae
      self.nixosModules.vicinae-wallpapers
      self.nixosModules.swayosd
      self.nixosModules.mime-defaults
      self.nixosModules.bibata-cursor
      self.nixosModules.qt

      self.nixosModules.discord
      self.nixosModules.gimp

      self.nixosModules.email
      self.nixosModules.rbw
      self.nixosModules.vault
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
      self.nixosModules.ai
      self.nixosModules.music
      self.nixosModules.doas
      self.nixosModules.reticulum
      self.nixosModules.kdeconnect
      # On AC always, but a laptop: alerts during a power cut.
      self.nixosModules.battery-notify
      self.nixosModules.dictation
      self.nixosModules.dictation-server
      self.nixosModules.openrgb
      self.nixosModules.activitywatch
      self.nixosModules.spotify
      self.nixosModules.gis
      self.nixosModules.gaming

      self.nixosModules.sops
      self.nixosModules.openssh
      self.nixosModules.nix-serve
      self.nixosModules.cable-link
      self.nixosModules.lan-discovery
      self.nixosModules.remote-deploy
      self.nixosModules.wifi-home
      self.nixosModules.syncthing
      self.nixosModules.immich

      self.nixosModules.powersave

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostButternut
    ];

    boot = {
      # LTS kernel: NVIDIA 595 does not build against 7.3 (strncpy removal).
      kernelPackages = pkgs.linuxPackages;

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

    # Music production stack (Ardour, plugins, yabridge, plugin paths).
    preferences.music.enable = true;

    # OpenRGB: no polling server; apply this profile at boot/resume.
    preferences.openrgb.profile = "night-time-coding";

    # Gaming: Steam games auto-offload to the RTX 3050; the gamescope greeter
    # session composites on the Intel iGPU (it drives the display).
    preferences.gaming.gamescopeVkDevice = "8086:46a6";

    # Desktop shell: "waybar" (waybar + swaync) or "noctalia" (Noctalia v5).
    preferences.desktopShell = "waybar";

    # Battery status for hazel's watcher (café: headless, unplugged).
    preferences.batteryAlert.serve.enable = true;

    # Dictation (Mod4+d): Whisper large-v3-turbo on the RTX 3050 (Vulkan,
    # loaded on demand, unloaded after 15 min), also serving hazel over the
    # cable/tailnet; Parakeet on the CPU if the server is down.
    preferences.dictation.servers = ["http://127.0.0.1:8178"];
    preferences.dictation-server.vulkanDriverFiles = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json";
    # The phone's profile, Parakeet files and APKs (Nixconf app, apps/phone/).
    preferences.dictation-server.phone.enable = true;

    # Auto-place apps on fixed workspaces (2 files/office, 3 audio, 4 browser,
    # 5 editor, 6 QGIS) — see modules/nixos/features/sway-workspaces.nix.
    preferences.sway.workspaceAssignments = true;

    # eno2: the home router (DHCP `lan`) or a direct cable to hazel (static
    # 10.42.0.1, hosts registry; `cable-mode` flips to a shared mode), picked
    # automatically (features/cable-link.nix). Binary cache served on eno2
    # (both cases) and the tailnet. `deploy hazel` pushes over the cable.
    preferences.cable.interface = "eno2";
    preferences.nix-serve.firewallInterfaces = ["eno2"];

    # Immich pilot (phone backup) until peacelily takes over: tailnet HTTPS on
    # 8444, as 443 is T3 Code and 8443 OpenCode (features/immich.nix).
    preferences.immich.tailscaleServePort = 8444;

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
    };

    programs.nix-ld.enable = true;
    programs.wayvnc.enable = true;

    # Host-specific sway keybindings
    home-manager.users.${config.preferences.user.name}.wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
      "Mod4+v" = "exec vicinae deeplink 'vicinae://launch/clipboard/history?toggle=true'";
      "Mod4+Shift+t" = "exec ${lib.getExe pkgs.darkman} toggle";
      "Mod4+period" = "exec vicinae deeplink 'vicinae://launch/core/search-emojis?toggle=true'";
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
