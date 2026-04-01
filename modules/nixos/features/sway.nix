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
    imports = [self.nixosModules.wofi-theme];

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

        # Keyboard: US + Arabic with Shift+Super toggle, CapsLock as Escape
        # Touchpad: tap-to-click, disable-while-typing
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

        # Pixel borders only, no title bars (zellij/waybar handle identification)
        window = {
          border = 4;
          titlebar = false;
        };

        floating.border = 1;

        focus.followMouse = "yes";

        # mkOptionDefault merges with sway's built-in defaults rather than replacing.
        # Host configs can add more keybindings with mkOptionDefault too.
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
          "${mod}+Shift+q" = "kill";
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

          # Screenshot
          "${mod}+Shift+s" = "exec ${lib.getExe pkgs.flameshot} gui";

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

        # Title bar font (visible if titlebar is ever re-enabled)
        fonts = {
          names = [self.fonts.monospace];
          size = self.fonts.size * 0.8;
        };

        # Disable sway's built-in bar — waybar is used instead
        bars = [];

        # Catppuccin Latte window decoration colors
        # (darkman does not switch these — they are build-time only)
        colors = let
          cat = self.catppuccin;
        in {
          focused = {
            border = cat.lavender;
            background = cat.base;
            text = cat.text;
            indicator = cat.mauve;
            childBorder = cat.lavender;
          };
          focusedInactive = {
            border = cat.surface1;
            background = cat.mantle;
            text = cat.subtext0;
            indicator = cat.surface1;
            childBorder = cat.surface1;
          };
          unfocused = {
            border = cat.surface0;
            background = cat.mantle;
            text = cat.overlay0;
            indicator = cat.surface0;
            childBorder = cat.surface0;
          };
          urgent = {
            border = cat.red;
            background = cat.base;
            text = cat.red;
            indicator = cat.red;
            childBorder = cat.red;
          };
          placeholder = {
            border = cat.crust;
            background = cat.crust;
            text = cat.text;
            indicator = cat.crust;
            childBorder = cat.crust;
          };
          background = cat.base;
        };

        # Export Wayland env vars into systemd and dbus so child services
        # (waybar, clipse, darkman, etc.) can access the compositor.
        # Then run each preferences.autostart entry as an exec command.
        startup =
          [
            {
              command = "systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && dbus-update-activation-environment --systemd DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP";
              always = true;
            }
          ]
          ++ map (entry: {
            command = lib.getExe entry;
          })
          config.preferences.autostart;

        # Map monitor preferences to sway outputs.
        # Disabled monitors get an explicit disable directive.
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

      # Per-app window rules (floating dialogs, sizing overrides)
      extraConfig = ''
        for_window [app_id="clipse"] floating enable, move position center, resize set 80ppt 80ppt
      '';
    };

    # Sway companion utilities — clipboard, screenshots, launcher, media keys
    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      flameshot
      wofi
      playerctl
      brightnessctl
    ];

    # Required for brightnessctl without root
    users.users.${user}.extraGroups = ["video"];

    # XDG portal for screen sharing, file chooser dialogs, etc.
    # wlr portal handles screen capture; gtk portal handles file dialogs.
    xdg.portal = {
      enable = true;
      wlr.enable = true;
      extraPortals = [pkgs.xdg-desktop-portal-gtk];
      config.sway = {
        default = lib.mkForce ["wlr" "gtk"];
      };
    };

    # Force Wayland for Qt, Firefox, and Electron apps
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
