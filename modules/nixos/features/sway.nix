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
    d = self.design;

    # Window decoration colours as sway commands — palette-only, included by
    # the config and replayed over IPC on a mode switch (no `swaymsg reload`,
    # which would reset the keyboard layout and re-run exec_always).
    # Focused = the focus ring (accent, ≥3:1 on every surface), everything
    # else a hairline in outlineVariant; urgent = error. No title bars, so
    # only border / indicator / child_border show; the title colours are set
    # for the day they are (onSelection on selection for the focused one).
    mkSwayColors = p: ''
      client.focused ${p.focus} ${p.selection} ${p.onSelection} ${p.accent} ${p.focus}
      client.focused_inactive ${p.outlineVariant} ${p.surfaceContainerLow} ${p.fgMuted} ${p.outlineVariant} ${p.outlineVariant}
      client.unfocused ${p.outlineVariant} ${p.surfaceContainerLow} ${p.fgMuted} ${p.outlineVariant} ${p.outlineVariant}
      client.urgent ${p.error} ${p.error} ${p.onError} ${p.error} ${p.error}
      client.placeholder ${p.surfaceContainerLow} ${p.surfaceContainerLow} ${p.fg} ${p.surfaceContainerLow} ${p.surfaceContainerLow}
      client.background ${p.surface}
    '';

    # Replay a sway-colors-style file (one command per line) over IPC.
    replayColors = file: ''
      while IFS= read -r line; do
        [ -n "$line" ] && ${pkgs.sway}/bin/swaymsg -- "$line" >/dev/null
      done < ${file}
    '';

    # Binding-mode look (resize, passthrough, mark, goto): the focus ring
    # turns the mode colour and thickens (smart borders off, so a lone window
    # shows it too), following focus (focus follows the mouse) until the mode
    # is left. Driven by the mode event rather than the bindings, so every
    # way out restores the look.
    #
    # Marked windows (Mod+m <letter>) wear a title bar — the only per-window
    # decoration sway has (border colours are per focus state) — which shows
    # the window title and, right-aligned, its mark. Kept in sync on every
    # mark event; marks starting with "_" (internal, hidden) don't count.
    smartBorders = "on";
    modeLook = pkgs.writeShellApplication {
      name = "sway-mode-look";
      runtimeInputs = [pkgs.sway pkgs.jq];
      text = ''
        set +e
        ringed=""
        pixel="border pixel ${toString d.window.border}"
        titled="border normal ${toString d.window.border}"
        replay() {
          ${replayColors ''"${theme.stateDir}/current/$1"''}
        }
        # The resting border of a window: titled while it carries a mark.
        rest() {
          if swaymsg -t get_tree -r | jq -e --argjson id "$1" 'first(.. | objects | select(.id == $id))
            | any((.marks // [])[]; startswith("_") | not)' >/dev/null; then
            echo "$titled"
          else
            echo "$pixel"
          fi
        }
        unring() {
          [ -n "$ringed" ] && swaymsg "[con_id=$ringed] $(rest "$ringed")" >/dev/null
          ringed=""
        }
        ring() {
          [ -z "$1" ] || [ "$1" = "$ringed" ] && return
          unring
          swaymsg "[con_id=$1] border pixel ${toString d.window.resizeBorder}" >/dev/null && ringed=$1
        }
        # Title bars on exactly the marked windows (the ringed one keeps its
        # ring until the mode ends).
        sync_marks() {
          cmds=$(swaymsg -t get_tree -r | jq -r --arg ringed "$ringed" --arg pixel "$pixel" --arg titled "$titled" '
            [.. | objects | select((.type == "con" or .type == "floating_con") and .pid != null)
              | select((.id | tostring) != $ringed)
              | (any((.marks // [])[]; startswith("_") | not)) as $m
              | if $m and .border != "normal" then "[con_id=\(.id)] \($titled)"
                elif ($m | not) and .border == "normal" then "[con_id=\(.id)] \($pixel)"
                else empty end] | join("; ")')
          [ -n "$cmds" ] && swaymsg -- "$cmds" >/dev/null
        }
        focused() {
          swaymsg -t get_tree -r | jq -r 'first(.. | objects
            | select(.focused == true and (.type == "con" or .type == "floating_con")) | .id) // empty'
        }
        # Re-subscribe if sway restarts or the socket is not up yet.
        while true; do
          mode=default
          sync_marks
          swaymsg -m -r -t subscribe '["mode", "window"]' 2>/dev/null \
            | jq -r --unbuffered 'if has("container")
                then (select(.change == "focus" or .change == "mark") | "\(.change) \(.container.id)")
                else "mode \(.change)" end' \
            | while read -r kind arg; do
                case "$kind:$arg" in
                  mode:default)
                    [ "$mode" = default ] && continue
                    mode=default
                    unring
                    swaymsg smart_borders ${smartBorders} >/dev/null
                    replay sway-colors
                    ;;
                  mode:*)
                    # Mode to mode (e.g. resize → passthrough): already lit.
                    if [ "$mode" = default ]; then
                      replay sway-colors-mode
                      swaymsg smart_borders off >/dev/null
                    fi
                    mode=$arg
                    ring "$(focused)"
                    ;;
                  focus:*)
                    [ "$mode" = default ] || ring "$arg"
                    ;;
                  mark:*)
                    sync_marks
                    ;;
                esac
              done
          sleep 1
        done
      '';
    };

    # Drop-down terminal (Mod+grave): one kitty with its own app id, kept in
    # the scratchpad; started on first use, toggled after that.
    dropdown = pkgs.writeShellApplication {
      name = "sway-dropdown";
      runtimeInputs = [pkgs.sway pkgs.jq];
      text = ''
        if swaymsg -t get_tree -r | jq -e 'any(.. | objects; .app_id? == "dropdown")' >/dev/null; then
          exec swaymsg '[app_id="^dropdown$"] scratchpad show'
        fi
        exec ${terminal} --class dropdown
      '';
    };

    # Focus mode (Mod+z): toggles the preferences.focusMode hooks.
    focusMode = pkgs.writeShellApplication {
      name = "focus-mode";
      runtimeInputs = [pkgs.sway pkgs.coreutils];
      text = ''
        set +e
        FOCUS_STATE="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/focus-mode"
        export FOCUS_STATE
        if [ -e "$FOCUS_STATE/on" ]; then
          ${config.preferences.focusMode.leave}
          rm -rf "$FOCUS_STATE"
        else
          mkdir -p "$FOCUS_STATE" && touch "$FOCUS_STATE/on"
          ${config.preferences.focusMode.enter}
        fi
      '';
    };

    # Vim-style marks: Mod+m <letter> marks the focused window, Mod+'
    # <letter> jumps to it (from any workspace); Backspace in the mark mode
    # clears the focused window's marks. `mode default` first, so a letter
    # with no mark still leaves the mode.
    letters = lib.stringToCharacters "abcdefghijklmnopqrstuvwxyz";
    letterMode = cmd:
      lib.genAttrs letters (l: "mode default; ${cmd l}")
      // {
        "Escape" = "mode default";
        "Return" = "mode default";
      };
  in {
    # Focus mode, sway's part: no gaps.
    preferences.focusMode = {
      enter = "swaymsg gaps inner all set 0 >/dev/null";
      leave = "swaymsg gaps inner all set ${toString d.window.gap} >/dev/null";
    };

    preferences.theme = {
      files."sway-colors" = mkSwayColors;
      files."sway-colors-mode" = p: ''
        client.focused ${p.mode} ${p.mode} ${p.onMode} ${p.mode} ${p.mode}
      '';
      reloadHooks.sway = ''
        if [ -z "''${SWAYSOCK:-}" ]; then
          SWAYSOCK="$(${pkgs.coreutils}/bin/ls -t /run/user/"$(${pkgs.coreutils}/bin/id -u)"/sway-ipc.*.sock 2>/dev/null | ${pkgs.coreutils}/bin/head -n1)"
          export SWAYSOCK
        fi
        [ -S "''${SWAYSOCK:-}" ] || exit 0
        ${replayColors "${theme.stateDir}/current/sway-colors"}
      '';
    };

    # wofi-theme: still used by wofi --dmenu prompts (e.g. wofi-emoji).
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
      systemd.user.services.sway-mode-look = {
        Unit = {
          Description = "Sway binding-mode focus ring and mark title bars";
          After = ["sway-session.target"];
          Requisite = ["sway-session.target"];
          PartOf = ["sway-session.target"];
        };
        Service = {
          ExecStart = lib.getExe modeLook;
          Restart = "on-failure";
        };
        Install.WantedBy = ["sway-session.target"];
      };

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

          # Calm tiling: the design system's gap (= the bar's edge padding)
          # between windows, none at the screen edge, and no gaps/borders at
          # all when a workspace holds a single window.
          gaps = {
            inner = d.window.gap;
            outer = 0;
            smartGaps = true;
            inherit smartBorders;
          };

          # Pixel borders only (the focus ring width), no title bars
          # (zellij/waybar handle identification).
          window = {
            border = d.window.border;
            titlebar = false;
          };

          floating.border = d.window.border;

          # Floating where tiling only gets in the way: picture-in-picture
          # (Firefox/Chromium) sticky in the bottom-right, the portal file
          # chooser and the settings applets centred, the drop-down terminal
          # across the top and in the scratchpad.
          window.commands = [
            {
              criteria.title = "^Picture[- ]in[- ][Pp]icture$";
              command = "floating enable, sticky enable, resize set width 25 ppt height 25 ppt, move position 73 ppt 73 ppt";
            }
            {
              criteria.app_id = "^xdg-desktop-portal-gtk$";
              command = "floating enable, resize set width 60 ppt height 70 ppt, move position center";
            }
            {
              criteria.app_id = "^(blueman-manager|nm-connection-editor|org\\.pulseaudio\\.pavucontrol)$";
              command = "floating enable, resize set width 40 ppt height 60 ppt, move position center";
            }
            {
              criteria.app_id = "^dropdown$";
              command = "floating enable, resize set width 80 ppt height 45 ppt, move position 10 ppt 0 ppt, move scratchpad, scratchpad show";
            }
          ];

          # Mod+<n> on the current workspace goes back to the previous one.
          workspaceAutoBackAndForth = true;

          focus.followMouse = "yes";
          # A window asking for focus (an agent opening a browser tab) is
          # marked urgent instead of taking it; Mod+u jumps there.
          focus.newWindow = "urgent";

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
            # No exit shortcut (home-manager's swaynag prompt): the session
            # is ended from the launcher's power menu.
            "${mod}+Shift+e" = null;
            # home-manager default already bound elsewhere: reload is Mod+Shift+d.
            "${mod}+Shift+c" = null;
            "${mod}+b" = null;

            "${mod}+u" = "[urgent=latest] focus";
            "${mod}+grave" = "exec ${lib.getExe dropdown}";
            "${mod}+z" = "exec ${lib.getExe focusMode}";
            "${mod}+m" = "mode mark";
            "${mod}+apostrophe" = "mode goto";
            # Every key to the focused app (VMs, remote desktops, games)
            # until the same combo again.
            "${mod}+Shift+Escape" = "mode passthrough";

            # Layout
            "${mod}+s" = "layout stacking";
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

          modes.mark =
            letterMode (l: "mark --replace ${l}")
            // {"BackSpace" = "mode default; [con_id=__focused__] unmark";};
          modes.goto = letterMode (l: ''[con_mark="^${l}$"] focus'');
          modes.passthrough."${mod}+Shift+Escape" = "mode default";

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
            names = [d.type.family.ui];
            size = d.type.size.body * 0.75; # pt
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
