{self, ...}: {
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "Mod4";
    user = config.preferences.user.name;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    terminal = lib.getExe selfpkgs.terminal;
    # Sway refuses to start while the proprietary nvidia kernel module is
    # loaded unless passed --unsupported-gpu (e.g. PRIME offload hosts).
    swayExtraOptions = lib.optional (lib.elem "nvidia" config.services.xserver.videoDrivers) "--unsupported-gpu";
    kb = config.preferences.keyboard;
    theme = config.preferences.theme;

    # Window decoration colours as sway commands — palette-only, included by
    # the config and replayed over IPC on a mode switch (no `swaymsg reload`,
    # which would reset the keyboard layout and re-run exec_always).
    # Focused = accent, everything else = surface0; 2px, no title bars.
    mkSwayColors = p: ''
      client.focused ${p.accent} ${p.surface} ${p.fg} ${p.accent} ${p.accent}
      client.focused_inactive ${p.surface0} ${p.surfaceContainerLow} ${p.fgMuted} ${p.surface0} ${p.surface0}
      client.unfocused ${p.surface0} ${p.surfaceContainerLow} ${p.fgFaint} ${p.surface0} ${p.surface0}
      client.urgent ${p.error} ${p.surface} ${p.error} ${p.error} ${p.error}
      client.placeholder ${p.crust} ${p.crust} ${p.fg} ${p.crust} ${p.crust}
      client.background ${p.surface}
    '';
  in {
    preferences.theme = {
      files."sway-colors" = mkSwayColors;
      reloadHooks.sway = ''
        if [ -z "''${SWAYSOCK:-}" ]; then
          SWAYSOCK="$(${pkgs.coreutils}/bin/ls -t /run/user/"$(${pkgs.coreutils}/bin/id -u)"/sway-ipc.*.sock 2>/dev/null | ${pkgs.coreutils}/bin/head -n1)"
          export SWAYSOCK
        fi
        [ -S "''${SWAYSOCK:-}" ] || exit 0
        while IFS= read -r line; do
          [ -n "$line" ] && ${pkgs.sway}/bin/swaymsg -- "$line" >/dev/null
        done < ${theme.stateDir}/current/sway-colors
      '';
    };

    # wofi-theme: still used by wofi --dmenu prompts (e.g. whisper-live).
    imports = [self.nixosModules.wofi-theme];

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
      extraOptions = swayExtraOptions;
    };

    # Ensure the wayland-sessions .desktop file is linked into
    # /run/current-system/sw/share/wayland-sessions so greetd/tuigreet can find it.
    environment.pathsToLink = ["/share/wayland-sessions"];

    # Flameshot is driven by Mod4+Shift+s; its tray icon only adds clutter.
    # flameshot.ini stays user-writable (savePath etc.), so set just the key.
    home-manager.users.${user} = {
      home.activation.flameshotNoTray = {
        after = ["writeBoundary"];
        before = [];
        data = ''
          run mkdir -p "$HOME/.config/flameshot"
          run ${lib.getExe pkgs.crudini} --set "$HOME/.config/flameshot/flameshot.ini" General disabledTrayIcon true
        '';
      };

      wayland.windowManager.sway = {
        enable = true;

        # Colours come from the theme state dir (light/dark switches live).
        # Later client.* lines override home-manager's built-in defaults.
        extraConfig = ''
          include ${theme.stateDir}/current/sway-colors
        '';
        # The HM sway wrapper comes first in PATH, so it needs the flag too.
        extraOptions = swayExtraOptions;

        config = {
          modifier = mod;
          terminal = terminal;
          menu = "vicinae toggle";

          # Keyboard: preferences.keyboard (default US + Arabic, Alt+Shift
          # toggles, CapsLock as Escape).
          # Touchpad: tap-to-click, disable-while-typing
          input = {
            "type:keyboard" = {
              xkb_layout = lib.concatStringsSep "," kb.layouts;
              xkb_options = lib.concatStringsSep "," ([kb.toggle] ++ kb.extraOptions);
            };
            "type:touchpad" = {
              dwt = "enabled";
              tap = "enabled";
              natural_scroll = "disabled";
              middle_emulation = "enabled";
            };
          };

          # Calm tiling: small inner gaps, none at the screen edge, and no
          # gaps/borders at all when a workspace holds a single window.
          gaps = {
            inner = 6;
            outer = 0;
            smartGaps = true;
            smartBorders = "on";
          };

          # Pixel borders only, no title bars (zellij/waybar handle identification)
          window = {
            border = 2;
            titlebar = false;
          };

          floating.border = 2;

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
            "${mod}+space" = "exec vicinae toggle";
            # Window picker, heaviest (summed RSS) first: focus / close.
            "${mod}+Tab" = "exec ${lib.getExe selfpkgs.window-switch}";
            "${mod}+Shift+Tab" = "exec ${lib.getExe selfpkgs.window-kill}";
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
            names = [self.fonts.sansSerif];
            size = self.fonts.size * 0.8;
          };

          # Disable sway's built-in bar — waybar is used instead
          bars = [];

          # Export Wayland env vars into systemd and dbus so child services
          # (waybar, vicinae, darkman, etc.) can access the compositor.
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
          # mkOptionDefault so hosts can merge additional output attrs (e.g. scale).
          output = lib.mkOptionDefault (
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
            config.preferences.monitors
          );
        };
      };
    };

    # Sway companion utilities — clipboard, screenshots, launcher, media keys
    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      flameshot
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
      # Without an explicit chooser, xdg-desktop-portal-wlr auto-probes for
      # fuzzel/wofi/rofi/... — none of which are on the portal service's PATH —
      # then fails every capture request with "wlroots: no output found".
      # This broke Firefox screenshare and Chromium window-sharing entirely.
      # "simple" + slurp lets the user click the output/region to share.
      wlr.settings.screencast = {
        chooser_type = "simple";
        chooser_cmd = "${lib.getExe pkgs.slurp} -f '%o' -or";
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
