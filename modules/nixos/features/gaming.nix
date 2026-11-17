{...}: {
  # Occasional gaming that "just works" from the launcher:
  #   - Steam (+ Proton-GE), with every game rendered on the NVIDIA dGPU via
  #     PRIME render offload (no per-game launch options needed)
  #   - a "Steam (gamescope)" SteamOS-like session in the greeter
  #   - Lutris (GOG/wine games, e.g. BioShock Remastered) and PCSX2 (PS2)
  #   - Xbox controllers: USB via the in-kernel xpad driver, Bluetooth via
  #     xpadneo
  # Hosts with PRIME offload set preferences.gaming.primeOffload (default on
  # when hardware.nvidia.prime.offload is enabled).
  flake.nixosModules.gaming = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.gaming;

    # NVIDIA PRIME render-offload environment (same as `nvidia-offload`).
    offloadEnv = {
      __NV_PRIME_RENDER_OFFLOAD = "1";
      __NV_PRIME_RENDER_OFFLOAD_PROVIDER = "NVIDIA-G0";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      __VK_LAYER_NV_optimus = "NVIDIA_only";
    };

    # The upstream steam module registers its gamescope session through
    # services.displayManager.sessionPackages, which is not linked into
    # /run/current-system/sw/share/wayland-sessions (where tuigreet looks).
    # Ship our own entry there; `steam-gamescope` is installed by the module.
    gamescopeSessionEntry = pkgs.writeTextDir "share/wayland-sessions/steam-gamescope.desktop" ''
      [Desktop Entry]
      Name=Steam (gamescope)
      Comment=SteamOS-like Big Picture session
      Exec=steam-gamescope
      Type=Application
    '';
  in {
    options.preferences.gaming = {
      primeOffload = lib.mkOption {
        type = lib.types.bool;
        default = config.hardware.nvidia.prime.offload.enable or false;
        description = "Render Steam (and thus all its games) on the NVIDIA dGPU via PRIME offload.";
      };
      gamescopeVkDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "8086:46a6";
        description = ''
          Vulkan device (vendor:device) gamescope composites on in the
          greeter session. On hybrid laptops set it to the GPU that drives the
          display; games are still offloaded to the dGPU.
        '';
      };
    };

    config = {
      programs = {
        gamemode.enable = true;
        gamescope.enable = true;

        steam = {
          enable = true;
          package = pkgs.steam.override {
            extraEnv = lib.optionalAttrs cfg.primeOffload offloadEnv;
          };
          extraCompatPackages = [pkgs.proton-ge-bin];
          protontricks.enable = true;
          remotePlay.openFirewall = false;

          gamescopeSession = {
            enable = true;
            args =
              ["--fullscreen" "--adaptive-sync"]
              ++ lib.optionals (cfg.gamescopeVkDevice != null) ["--prefer-vk-device" cfg.gamescopeVkDevice];
          };
        };
      };

      environment.pathsToLink = ["/share/wayland-sessions"];

      environment.systemPackages = with pkgs; [
        gamescopeSessionEntry
        lutris # GOG/wine games (BioShock Remastered) + existing PS2 entries
        pcsx2 # PS2 emulator; needs a user-dumped BIOS in ~/.config/PCSX2/bios
        mangohud
        evtest-qt # controller tester
      ];

      # Xbox One/Series controllers over Bluetooth. USB uses in-kernel xpad.
      hardware.xpadneo.enable = true;
      hardware.bluetooth.settings.General = {
        # Re-pairing/reconnecting Xbox controllers without a PIN prompt and
        # without the controller failing on a privacy-mode adapter.
        Privacy = "device";
        JustWorksRepairing = "always";
        FastConnectable = true;
      };

      persistance.cache.directories = [
        ".local/share/Steam"
        ".local/share/lutris"
        ".config/PCSX2"
        "Games"
      ];
    };
  };
}
