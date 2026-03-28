{self, ...}: {
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "Mod4";
    user = config.preferences.user.name;
    terminal = lib.getExe self.packages.${pkgs.system}.terminal;
  in {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    # Ensure the wayland-sessions .desktop file is linked into
    # /run/current-system/sw/share/wayland-sessions so greetd/tuigreet can find it.
    environment.pathsToLink = ["/share/wayland-sessions"];

    home-manager.users.${user}.wayland.windowManager.sway = {
      enable = true;

      config = {
        modifier = mod;
        terminal = terminal;
        menu = "wofi --show drun";

        input = {
          "type:keyboard" = {
            xkb_layout = "us,ara";
            xkb_options = "grp:shift_super_toggle,caps:escape";
          };
          "type:touchpad" = {
            dwt = "enabled";
            tap = "enabled";
            natural_scroll = "disabled";
            middle_emulation = "enabled";
          };
        };

        gaps.inner = 8;

        window = {
          border = 4;
          titlebar = false;
        };

        floating.border = 1;

        focus.followMouse = "yes";

        keybindings = lib.mkOptionDefault {
          # Navigation
          "${mod}+Left" = "focus left";
          "${mod}+Down" = "focus down";
          "${mod}+Up" = "focus up";
          "${mod}+Right" = "focus right";
          "${mod}+h" = "focus left";
          "${mod}+j" = "focus down";
          "${mod}+k" = "focus up";
          "${mod}+l" = "focus right";

          # Move windows
          "${mod}+Shift+Left" = "move left";
          "${mod}+Shift+Down" = "move down";
          "${mod}+Shift+Up" = "move up";
          "${mod}+Shift+Right" = "move right";
          "${mod}+Shift+h" = "move left";
          "${mod}+Shift+j" = "move down";
          "${mod}+Shift+k" = "move up";
          "${mod}+Shift+l" = "move right";

          # Core actions
          "${mod}+Return" = "exec ${terminal}";
          "${mod}+Shift+c" = "kill";
          "${mod}+space" = "exec wofi --show drun";
          "${mod}+f" = "fullscreen toggle";
          "${mod}+Shift+f" = "floating toggle";
          "${mod}+a" = "focus parent";
          "${mod}+Shift+d" = "reload";

          # Layout
          "${mod}+i" = "layout stacking";
          "${mod}+w" = "layout tabbed";
          "${mod}+e" = "layout toggle split";

          # Scratchpad
          "${mod}+Shift+minus" = "move scratchpad";
          "${mod}+minus" = "scratchpad show";

          # Audio
          "--locked XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
          "--locked XF86AudioLowerVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-";
          "--locked XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
          "--locked XF86AudioMicMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

          # Media
          "--locked XF86AudioPlay" = "exec playerctl play-pause";
          "--locked XF86AudioNext" = "exec playerctl next";
          "--locked XF86AudioPrev" = "exec playerctl previous";

          # Brightness
          "XF86MonBrightnessUp" = "exec brightnessctl set 5%+";
          "XF86MonBrightnessDown" = "exec brightnessctl set 5%-";
          "Shift+XF86MonBrightnessUp" = "exec brightnessctl set 1%+";
          "Shift+XF86MonBrightnessDown" = "exec brightnessctl set 1%-";

          # Resize mode
          "${mod}+r" = "mode \"resize\"";

          # Workspaces
          "${mod}+1" = "workspace number 1";
          "${mod}+2" = "workspace number 2";
          "${mod}+3" = "workspace number 3";
          "${mod}+4" = "workspace number 4";
          "${mod}+5" = "workspace number 5";
          "${mod}+6" = "workspace number 6";
          "${mod}+7" = "workspace number 7";
          "${mod}+8" = "workspace number 8";
          "${mod}+9" = "workspace number 9";
          "${mod}+Shift+1" = "move container to workspace number 1";
          "${mod}+Shift+2" = "move container to workspace number 2";
          "${mod}+Shift+3" = "move container to workspace number 3";
          "${mod}+Shift+4" = "move container to workspace number 4";
          "${mod}+Shift+5" = "move container to workspace number 5";
          "${mod}+Shift+6" = "move container to workspace number 6";
          "${mod}+Shift+7" = "move container to workspace number 7";
          "${mod}+Shift+8" = "move container to workspace number 8";
          "${mod}+Shift+9" = "move container to workspace number 9";
        };

        modes.resize = {
          "Left" = "resize shrink width 10px";
          "Down" = "resize grow height 10px";
          "Up" = "resize shrink height 10px";
          "Right" = "resize grow width 10px";
          "Return" = "mode default";
          "Escape" = "mode default";
        };

        startup = [
          {
            command = "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP";
            always = true;
          }
        ];

        output =
          lib.mapAttrs (
            _name: m:
              if m.enabled
              then {
                resolution = "${toString m.width}x${toString m.height}@${toString m.refreshRate}Hz";
                position = "${toString m.x} ${toString m.y}";
              }
              else {
                disable = "";
              }
          )
          config.preferences.monitors;
      };
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      wofi
      playerctl
      brightnessctl
    ];

    users.users.${user}.extraGroups = ["video"];

    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.sway = {
        default = lib.mkForce ["wlr" "gtk"];
      };
    };

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      QT_WAYLAND_DISABLE_WINDOWDECORATION = "1";
      MOZ_ENABLE_WAYLAND = "1";
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "sway";
      NIXOS_OZONE_WL = "1";
    };
  };
}
