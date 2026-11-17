{...}: {
  # Occasional gaming that "just works" from the launcher:
  #   - Steam (+ Proton-GE), with every game rendered on the NVIDIA dGPU via
  #     PRIME render offload (no per-game launch options needed)
  #   - a "Steam (gamescope)" SteamOS-like session in the greeter
  #   - Lutris (GOG/wine games, e.g. BioShock Remastered)
  #   - PS2 via PCSX2 (preferences.gaming.ps2): managed PCSX2.ini keys (Vulkan,
  #     fullscreen, SDL pad), one `game-<id>` launcher per disc image. The
  #     user drops in their own BIOS/disc dumps; nothing is downloaded.
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

    # Non-Steam Windows games: one launcher per game, run with umu + GE-Proton
    # on an existing Wine prefix, offloaded to the dGPU, under gamemode.
    mkGameLauncher = id: g:
      pkgs.writeShellApplication {
        name = "game-${id}";
        runtimeInputs = [pkgs.umu-launcher pkgs.gamemode];
        text = ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}")
              ((lib.optionalAttrs cfg.primeOffload offloadEnv) // g.env))}
          export WINEPREFIX="$HOME/${g.prefix}"
          export PROTONPATH=${pkgs.proton-ge-bin.steamcompattool}
          export GAMEID=${lib.escapeShellArg g.gameId}
          exe="$WINEPREFIX/${g.exe}"
          cd "$(dirname "$exe")"
          exec gamemoderun umu-run "$exe" ${lib.escapeShellArgs g.args} "$@"
        '';
      };

    gameLaunchers = lib.mapAttrs mkGameLauncher cfg.games;

    # --- PS2 (PCSX2) -------------------------------------------------------
    # The user supplies the BIOS (dumped from their console) and the ISOs
    # (dumped from their discs); nothing copyrighted goes into the store.
    inherit (cfg) ps2;
    user = config.preferences.user.name;
    home = config.home-manager.users.${user}.home.homeDirectory;
    biosDir = "${home}/${ps2.biosDir}";
    gamesDir = "${home}/${ps2.gamesDir}";

    ps2Readme = pkgs.writeText "ps2-README.txt" ''
      PS2 games (PCSX2), set up by the nixconf gaming feature.

      BIOS: put your console's BIOS dump (the ~4 MB .bin, e.g. SCPH-xxxxx.bin,
      plus any .erom/.rom1/.nvm/.mec files that came with it) in:
        ${biosDir}/

      Games: put your disc dumps here, named exactly:
      ${lib.concatStrings (lib.mapAttrsToList (_: g: "  ${gamesDir}/${g.iso}   (${g.name})\n") ps2.games)}
      Then start the game from the launcher, or run game-<id> in a terminal.
      PCSX2 log: ~/.config/PCSX2/logs/emulog.txt
    '';

    # Keys merged into ~/.config/PCSX2/inis/PCSX2.ini on every activation.
    # Names checked against PCSX2 2.8 (pcsx2/Pcsx2Config.cpp, pcsx2-qt/QtHost.cpp,
    # pcsx2/SIO/Pad, pcsx2/Input/SDLInputSource.cpp).
    pcsx2Spec = pkgs.writeText "pcsx2-ini-spec.json" (builtins.toJSON {
      enforce = {
        # A missing/mismatched SettingsVersion makes PCSX2 reset everything.
        UI = {
          SettingsVersion = 1;
          SetupWizardIncomplete = false;
          StartFullscreen = true;
          HideMouseCursor = true;
        };
        Folders.Bios = biosDir; # absolute paths are used as-is
        GameList.Paths = gamesDir;
        "EmuCore/GS" = {
          Renderer = 14; # GSRendererType::VK
          upscale_multiplier = ps2.upscale;
        };
        InputSources = {
          SDL = true;
          SDLControllerEnhancedMode = true; # rumble/LEDs over Bluetooth
        };
        Pad1.Type = "DualShock2";
      };
      # PCSX2's own defaults for a fresh ini (no Hotkeys section otherwise).
      default.Hotkeys = {
        OpenPauseMenu = "Keyboard/Escape";
        ToggleFullscreen = "Keyboard/Alt & Keyboard/Return";
        SaveStateToSlot = "Keyboard/F1";
        NextSaveStateSlot = "Keyboard/F2";
        LoadStateFromSlot = "Keyboard/F3";
      };
      # What PCSX2's automapper produces for an SDL gamepad on DualShock2
      # (SDL-0 = first controller). Seeded once; later remaps are kept.
      bindings.Pad1 = {
        Up = "SDL-0/DPadUp";
        Right = "SDL-0/DPadRight";
        Down = "SDL-0/DPadDown";
        Left = "SDL-0/DPadLeft";
        Triangle = "SDL-0/FaceNorth";
        Circle = "SDL-0/FaceEast";
        Cross = "SDL-0/FaceSouth";
        Square = "SDL-0/FaceWest";
        Select = "SDL-0/Back";
        Start = "SDL-0/Start";
        L1 = "SDL-0/LeftShoulder";
        L2 = "SDL-0/+LeftTrigger";
        R1 = "SDL-0/RightShoulder";
        R2 = "SDL-0/+RightTrigger";
        L3 = "SDL-0/LeftStick";
        R3 = "SDL-0/RightStick";
        Analog = "SDL-0/Guide";
        LUp = "SDL-0/-LeftY";
        LRight = "SDL-0/+LeftX";
        LDown = "SDL-0/+LeftY";
        LLeft = "SDL-0/-LeftX";
        RUp = "SDL-0/-RightY";
        RRight = "SDL-0/+RightX";
        RDown = "SDL-0/+RightY";
        RLeft = "SDL-0/-RightX";
        LargeMotor = "SDL-0/LargeMotor";
        SmallMotor = "SDL-0/SmallMotor";
      };
    });

    pcsx2IniMerge = pkgs.writers.writePython3 "pcsx2-ini-merge" {} (builtins.readFile ./pcsx2-ini-merge.py);

    mkPs2Launcher = id: g:
      pkgs.writeShellApplication {
        name = "game-${id}";
        runtimeInputs = [pkgs.pcsx2 pkgs.gamemode pkgs.libnotify pkgs.findutils];
        text = ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}")
              (lib.optionalAttrs cfg.primeOffload offloadEnv))}
          bios=${lib.escapeShellArg biosDir}
          iso=${lib.escapeShellArg "${gamesDir}/${g.iso}"}
          missing() {
            notify-send -a ${lib.escapeShellArg g.name} -i dialog-warning "$1" "$2"
            echo "$1: $2" >&2
            exit 0
          }
          # A PS2 BIOS image is 4 MB; README.txt and .nvm/.mec files are tiny.
          if [ -z "$(find "$bios" -maxdepth 1 -type f -size +3M -print -quit 2>/dev/null)" ]; then
            missing "PS2 BIOS missing" "Put your console's BIOS dump (the ~4 MB .bin) in $bios/"
          fi
          if [ ! -f "$iso" ]; then
            missing ${lib.escapeShellArg "${g.name}: disc image missing"} "Put your disc dump at $iso"
          fi
          # -batch: quit PCSX2 when the game is shut down.
          exec gamemoderun pcsx2-qt -batch -fullscreen -- "$iso"
        '';
      };

    ps2Launchers = lib.mapAttrs mkPs2Launcher ps2.games;
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
      games = lib.mkOption {
        default = {};
        description = ''
          Non-Steam Windows games with an existing Wine prefix. Each gets a
          `game-<id>` command and a launcher entry (umu + GE-Proton, dGPU,
          gamemode).
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            name = lib.mkOption {type = lib.types.str;};
            prefix = lib.mkOption {
              type = lib.types.str;
              description = "Wine prefix, relative to $HOME.";
            };
            exe = lib.mkOption {
              type = lib.types.str;
              description = "Game executable, relative to the prefix.";
            };
            args = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
            };
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
            };
            gameId = lib.mkOption {
              type = lib.types.str;
              default = "umu-default";
              description = "umu-protonfixes game id (umu-<id> enables per-game fixes).";
            };
            icon = lib.mkOption {
              type = lib.types.str;
              default = "applications-games";
            };
          };
        });
      };

      ps2 = {
        enable = lib.mkEnableOption "PCSX2 with a managed config and per-game launchers";
        biosDir = lib.mkOption {
          type = lib.types.str;
          default = "Games/ps2/bios";
          description = "Where the user's own BIOS dump goes, relative to $HOME.";
        };
        gamesDir = lib.mkOption {
          type = lib.types.str;
          default = "Games/ps2";
          description = "PCSX2 game list directory (disc images), relative to $HOME.";
        };
        upscale = lib.mkOption {
          type = lib.types.ints.between 1 8;
          default = 3;
          description = "Internal resolution multiplier (3x native ~ 1080p+).";
        };
        games = lib.mkOption {
          default = {};
          description = ''
            PS2 games. Each gets a `game-<id>` command and a launcher entry
            that boots the disc image fullscreen (dGPU when PRIME offload is
            on), or explains via a notification which file is missing.
          '';
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              name = lib.mkOption {type = lib.types.str;};
              iso = lib.mkOption {
                type = lib.types.str;
                description = "Disc image file name, relative to gamesDir.";
              };
              icon = lib.mkOption {
                type = lib.types.str;
                default = "PCSX2";
              };
            };
          });
        };
      };
    };

    config = lib.mkMerge [
      {
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

        home-manager.users.${config.preferences.user.name}.xdg.desktopEntries =
          lib.mapAttrs (id: g: {
            inherit (g) name icon;
            exec = lib.getExe gameLaunchers.${id};
            categories = ["Game"];
          })
          cfg.games;

        environment.systemPackages = with pkgs;
          lib.attrValues gameLaunchers
          ++ [
            umu-launcher
            gamescopeSessionEntry
            lutris # GOG/wine games (BioShock Remastered) + existing PS2 entries
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
      }

      (lib.mkIf ps2.enable {
        environment.systemPackages = [pkgs.pcsx2] ++ lib.attrValues ps2Launchers;

        home-manager.users.${user} = {
          xdg.desktopEntries =
            lib.mapAttrs (id: g: {
              inherit (g) name icon;
              exec = lib.getExe ps2Launchers.${id};
              categories = ["Game"];
            })
            ps2.games;

          # Directories + README for the user's own dumps, and a key-level merge
          # into PCSX2.ini (PCSX2 rewrites the file, so it stays mutable).
          # (NixOS lib has no lib.hm: spell out the DAG entry.)
          home.activation.pcsx2Config = {
            after = ["writeBoundary"];
            before = [];
            data = ''
              run mkdir -p ${lib.escapeShellArg biosDir} ${lib.escapeShellArg gamesDir}
              run install -m 0644 ${ps2Readme} ${lib.escapeShellArg "${gamesDir}/README.txt"}
              run install -m 0644 ${ps2Readme} ${lib.escapeShellArg "${biosDir}/README.txt"}
              run ${pcsx2IniMerge} "''${XDG_CONFIG_HOME:-$HOME/.config}/PCSX2/inis/PCSX2.ini" ${pcsx2Spec}
            '';
          };
        };
      })
    ];
  };
}
