{self, ...}: {
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    mod = "Mod4";
    terminal = lib.getExe self.packages.${pkgs.system}.terminal;
  in {
    imports = [
      self.nixosModules.extra_hjem_sway
    ];

    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    home.programs.sway.enable = true;

    home.programs.sway.settings = {
      # Input
      "input type:keyboard" = {
        xkb_layout = "us,ara";
        xkb_options = "grp:shift_super_toggle,caps:escape";
      };

      "input type:touchpad" = {
        dwt = "enabled";
        tap = "enabled";
        natural_scroll = "disabled";
        middle_emulation = "enabled";
      };

      # Appearance
      gaps.inner = "8";
      default_border = "pixel 4";
      default_floating_border = "pixel 1";

      # Focus
      focus_follows_mouse = "yes";

      # Navigation
      "bindsym ${mod}+Left" = "focus left";
      "bindsym ${mod}+Down" = "focus down";
      "bindsym ${mod}+Up" = "focus up";
      "bindsym ${mod}+Right" = "focus right";
      "bindsym ${mod}+h" = "focus left";
      "bindsym ${mod}+j" = "focus down";
      "bindsym ${mod}+k" = "focus up";
      "bindsym ${mod}+l" = "focus right";

      # Move windows
      "bindsym ${mod}+Shift+Left" = "move left";
      "bindsym ${mod}+Shift+Down" = "move down";
      "bindsym ${mod}+Shift+Up" = "move up";
      "bindsym ${mod}+Shift+Right" = "move right";
      "bindsym ${mod}+Shift+h" = "move left";
      "bindsym ${mod}+Shift+j" = "move down";
      "bindsym ${mod}+Shift+k" = "move up";
      "bindsym ${mod}+Shift+l" = "move right";

      # Core actions
      "bindsym ${mod}+Return" = "exec ${terminal}";
      "bindsym ${mod}+Shift+c" = "kill";
      "bindsym ${mod}+space" = "exec wofi --show drun";
      "bindsym ${mod}+f" = "fullscreen toggle";
      "bindsym ${mod}+Shift+f" = "floating toggle";
      "bindsym ${mod}+a" = "focus parent";
      "bindsym ${mod}+Shift+d" = "reload";

      # Layout
      "bindsym ${mod}+i" = "layout stacking";
      "bindsym ${mod}+w" = "layout tabbed";
      "bindsym ${mod}+e" = "layout toggle split";

      # Scratchpad
      "bindsym ${mod}+Shift+minus" = "move scratchpad";
      "bindsym ${mod}+minus" = "scratchpad show";

      # Audio
      "bindsym --locked XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
      "bindsym --locked XF86AudioLowerVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-";
      "bindsym --locked XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      "bindsym --locked XF86AudioMicMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";

      # Media
      "bindsym --locked XF86AudioPlay" = "exec playerctl play-pause";
      "bindsym --locked XF86AudioNext" = "exec playerctl next";
      "bindsym --locked XF86AudioPrev" = "exec playerctl previous";

      # Brightness
      "bindsym XF86MonBrightnessUp" = "exec light -A 5";
      "bindsym XF86MonBrightnessDown" = "exec light -U 5";
      "bindsym Shift+XF86MonBrightnessUp" = "exec light -A 1";
      "bindsym Shift+XF86MonBrightnessDown" = "exec light -U 1";

      # Resize mode
      "mode \"resize\"" = {
        "bindsym Left" = "resize shrink width 10px";
        "bindsym Down" = "resize grow height 10px";
        "bindsym Up" = "resize shrink height 10px";
        "bindsym Right" = "resize grow width 10px";
        "bindsym Return" = "mode default";
        "bindsym Escape" = "mode default";
      };
      "bindsym ${mod}+r" = "mode \"resize\"";
    };

    # Workspace bindings + monitor config via extraConfig
    home.programs.sway.extraConfig = let
      workspaceBindings = lib.concatMapStringsSep "\n" (
        n: let
          ws = toString n;
        in ''
          bindsym ${mod}+${ws} workspace number ${ws}
          bindsym ${mod}+Shift+${ws} move container to workspace number ${ws}''
      ) [1 2 3 4 5 6 7 8 9];

      monitorConfig = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: m:
            if m.enabled
            then "output ${name} resolution ${toString m.width}x${toString m.height}@${toString m.refreshRate}Hz position ${toString m.x} ${toString m.y}"
            else "output ${name} disable"
        )
        config.preferences.monitors
      );
    in ''
      ${workspaceBindings}
      ${monitorConfig}
    '';

    environment.systemPackages = with pkgs; [
      wl-clipboard
      grim
      slurp
      wofi
      playerctl
    ];

    users.users.${config.preferences.user.name}.extraGroups = ["video"];

    programs.light.enable = true;

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

    # Import sway's environment into systemd/dbus so portals can find the display
    home.programs.sway.settings."exec_always" = "systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP && dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP";
  };
}
