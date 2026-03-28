{
  inputs,
  self,
  ...
}: {
  flake.wrapperModules.niri = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.terminal = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe self.packages.${config.pkgs.stdenv.hostPlatform.system}.terminal;
    };
    config = {
      settings = let
        # startNoctaliaExe = lib.getExe self.packages.${config.pkgs.stdenv.hostPlatform.system}.start-noctalia-shell;
        noctaliaExe = lib.getExe self.packages.${config.pkgs.stdenv.hostPlatform.system}.noctalia-shell;
      in {
        prefer-no-csd = null;

        input = {
          focus-follows-mouse = null;

          keyboard = {
            xkb = {
              layout = "us,ru,ua";
              options = "grp:alt_shift_toggle,caps:escape";
            };
            repeat-rate = 40;
            repeat-delay = 250;
          };

          touchpad = {
            natural-scroll = null;
            tap = null;
          };

          mouse = {
            accel-profile = "flat";
          };
        };

        binds = {
          "Mod+Return".spawn = config.terminal;

          "Mod+Q".close-window = null;
          "Mod+F".maximize-column = null;
          "Mod+G".fullscreen-window = null;
          "Mod+Shift+F".toggle-window-floating = null;
          "Mod+C".center-column = null;

          "Mod+H".focus-column-left = null;
          "Mod+L".focus-column-right = null;
          "Mod+K".focus-window-up = null;
          "Mod+J".focus-window-down = null;

          "Mod+Left".focus-column-left = null;
          "Mod+Right".focus-column-right = null;
          "Mod+Up".focus-window-up = null;
          "Mod+Down".focus-window-down = null;

          "Mod+Shift+H".move-column-left = null;
          "Mod+Shift+L".move-column-right = null;
          "Mod+Shift+K".move-window-up = null;
          "Mod+Shift+J".move-window-down = null;

          "Mod+1".focus-workspace = "w0";
          "Mod+2".focus-workspace = "w1";
          "Mod+3".focus-workspace = "w2";
          "Mod+4".focus-workspace = "w3";
          "Mod+5".focus-workspace = "w4";
          "Mod+6".focus-workspace = "w5";
          "Mod+7".focus-workspace = "w6";
          "Mod+8".focus-workspace = "w7";
          "Mod+9".focus-workspace = "w8";
          "Mod+0".focus-workspace = "w9";

          "Mod+Shift+1".move-column-to-workspace = "w0";
          "Mod+Shift+2".move-column-to-workspace = "w1";
          "Mod+Shift+3".move-column-to-workspace = "w2";
          "Mod+Shift+4".move-column-to-workspace = "w3";
          "Mod+Shift+5".move-column-to-workspace = "w4";
          "Mod+Shift+6".move-column-to-workspace = "w5";
          "Mod+Shift+7".move-column-to-workspace = "w6";
          "Mod+Shift+8".move-column-to-workspace = "w7";
          "Mod+Shift+9".move-column-to-workspace = "w8";
          "Mod+Shift+0".move-column-to-workspace = "w9";

          "Mod+S".spawn-sh = "${noctaliaExe} ipc call launcher toggle";
          "Mod+V".spawn-sh = ''${config.pkgs.alsa-utils}/bin/amixer sset Capture toggle'';

          "XF86AudioRaiseVolume".spawn-sh = "wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%+";
          "XF86AudioLowerVolume".spawn-sh = "wpctl set-volume -l 1.4 @DEFAULT_AUDIO_SINK@ 5%-";

          "Mod+Ctrl+H".set-column-width = "-5%";
          "Mod+Ctrl+L".set-column-width = "+5%";
          "Mod+Ctrl+J".set-window-height = "-5%";
          "Mod+Ctrl+K".set-window-height = "+5%";

          "Mod+WheelScrollDown".focus-column-left = null;
          "Mod+WheelScrollUp".focus-column-right = null;
          "Mod+Ctrl+WheelScrollDown".focus-workspace-down = null;
          "Mod+Ctrl+WheelScrollUp".focus-workspace-up = null;

          "Mod+Ctrl+S".spawn-sh = ''${lib.getExe config.pkgs.grim} -l 0 - | ${config.pkgs.wl-clipboard}/bin/wl-copy'';

          "Mod+Shift+E".spawn-sh = ''${config.pkgs.wl-clipboard}/bin/wl-paste | ${lib.getExe config.pkgs.swappy} -f -'';

          "Mod+Shift+S".spawn-sh = lib.getExe (config.pkgs.writeShellApplication {
            name = "screenshot";
            text = ''
              ${lib.getExe config.pkgs.grim} -g "$(${lib.getExe config.pkgs.slurp} -w 0)" - \
              | ${config.pkgs.wl-clipboard}/bin/wl-copy
            '';
          });

          "Mod+Shift+Slash".spawn-sh = self.mkWhichKeyExe config.pkgs [
            {
              key = "ret";
              desc = "Terminal";
              cmd = "";
            }
            {
              key = "q";
              desc = "Close window";
              cmd = "";
            }
            {
              key = "f";
              desc = "Maximize";
              cmd = "";
            }
            {
              key = "g";
              desc = "Fullscreen";
              cmd = "";
            }
            {
              key = "S-f";
              desc = "Float";
              cmd = "";
            }
            {
              key = "c";
              desc = "Center";
              cmd = "";
            }
            {
              key = "h/l";
              desc = "Focus left/right";
              cmd = "";
            }
            {
              key = "j/k";
              desc = "Focus down/up";
              cmd = "";
            }
            {
              key = "S-hjkl";
              desc = "Move window";
              cmd = "";
            }
            {
              key = "C-hl";
              desc = "Column width";
              cmd = "";
            }
            {
              key = "C-jk";
              desc = "Window height";
              cmd = "";
            }
            {
              key = "1-0";
              desc = "Workspace";
              cmd = "";
            }
            {
              key = "S-1-0";
              desc = "Move to workspace";
              cmd = "";
            }
            {
              key = "s";
              desc = "Launcher";
              cmd = "";
            }
            {
              key = "d";
              desc = "Quick menu";
              cmd = "";
            }
            {
              key = "C-s";
              desc = "Screenshot (full)";
              cmd = "";
            }
            {
              key = "S-s";
              desc = "Screenshot (area)";
              cmd = "";
            }
            {
              key = "S-e";
              desc = "Edit screenshot";
              cmd = "";
            }
            {
              key = "S-?";
              desc = "This help";
              cmd = "";
            }
          ];

          "Mod+d".spawn-sh = self.mkWhichKeyExe config.pkgs [
            {
              key = "b";
              desc = "Bluetooth";
              cmd = "${noctaliaExe} ipc call bluetooth togglePanel";
            }
            {
              key = "w";
              desc = "Wifi";
              cmd = "${noctaliaExe} ipc call wifi togglePanel";
            }
            {
              key = "f";
              desc = "Firefox";
              cmd = "firefox";
            }
            {
              key = "t";
              desc = "Telegram";
              cmd = "Telegram";
            }
            {
              key = "d";
              desc = "Discord";
              cmd = "vesktop";
            }
            {
              key = "m";
              desc = "Youtube Music";
              cmd = "pear-desktop";
            }
            {
              key = "s";
              desc = "Pavucontrol";
              cmd = "${lib.getExe pkgs.pavucontrol}";
            }
          ];
        };

        layout = {
          gaps = 5;

          focus-ring = {
            width = 2;
            active-color = "#${self.themeNoHash.base09}";
          };
        };

        workspaces = let
          settings = {layout.gaps = 5;};
        in {
          "w0" = settings;
          "w1" = settings;
          "w2" = settings;
          "w3" = settings;
          "w4" = settings;
          "w5" = settings;
          "w6" = settings;
          "w7" = settings;
          "w8" = settings;
          "w9" = settings;
        };

        xwayland-satellite.path =
          lib.getExe config.pkgs.xwayland-satellite;

        spawn-at-startup = [];
      };
    };
  };

  perSystem = {pkgs, ...}: {
    packages.niri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      imports = [self.wrapperModules.niri];
    };
  };
}
