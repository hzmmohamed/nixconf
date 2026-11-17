# SwayNotificationCenter — the notification daemon of the "waybar" desktop shell.
# Replaces mako: toasts + notification center + DND. Gated on
# preferences.desktopShell == "waybar" (in "noctalia" mode Noctalia owns
# notifications), so hosts can import it unconditionally.
{self, ...}: {
  flake.nixosModules.swaync = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    swaync = pkgs.swaynotificationcenter;
    client = "${swaync}/bin/swaync-client";

    mkColorsCss = cat: ''
      @define-color cat-text ${cat.text};
      @define-color cat-subtext0 ${cat.subtext0};
      @define-color cat-overlay0 ${cat.overlay0};
      @define-color cat-surface0 ${cat.surface0};
      @define-color cat-surface1 ${cat.surface1};
      @define-color cat-base ${cat.base};
      @define-color cat-mantle ${cat.mantle};
      @define-color cat-crust ${cat.crust};
      @define-color cat-lavender ${cat.lavender};
      @define-color cat-red ${cat.red};
    '';

    # `dnd on|off|toggle|status` — backend-specific; the same CLI exists in
    # noctalia mode so keybinds/timers/portal hooks stay identical.
    dnd = pkgs.writeShellScriptBin "dnd" ''
      case "''${1:-toggle}" in
        on) exec ${client} -sw -dn >/dev/null ;;
        off) exec ${client} -sw -df >/dev/null ;;
        toggle) exec ${client} -sw -d >/dev/null ;;
        status) [ "$(${client} -sw -D)" = true ] && echo on || echo off ;;
        *) echo "usage: dnd on|off|toggle|status" >&2; exit 1 ;;
      esac
    '';
    dndToggle = pkgs.writeShellScriptBin "dnd-toggle" ''exec ${dnd}/bin/dnd toggle'';

    # Screen sharing: force DND on, restore the previous state afterwards.
    screenshareDndOn = pkgs.writeShellScript "screenshare-dnd-on" ''
      state="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dnd-before-screenshare"
      [ -e "$state" ] || ${dnd}/bin/dnd status >"$state"
      ${dnd}/bin/dnd on
    '';
    screenshareDndOff = pkgs.writeShellScript "screenshare-dnd-off" ''
      state="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/dnd-before-screenshare"
      [ -e "$state" ] || exit 0
      prev=$(cat "$state"); rm -f "$state"
      [ "$prev" = off ] && ${dnd}/bin/dnd off
      exit 0
    '';

    style = ''
      @import url("file://${home}/.config/swaync/colors.css");

      * {
        font-family: "${self.fonts.sansSerif}";
        font-size: ${toString self.fonts.size}px;
      }

      /* Layer-shell host windows: not visible surfaces themselves. */
      .floating-notifications, .blank-window { background: none; }

      .notification-row, .notification-row:hover, .notification-row:focus {
        background: none;
        outline: none;
      }

      .notification {
        background: @cat-base;
        color: @cat-text;
        border: 1px solid @cat-surface1;
        border-radius: 8px;
        margin: 6px;
        padding: 0;
        box-shadow: none;
      }
      .notification.critical { border-color: @cat-red; }
      .notification-content { padding: 10px; }
      .summary { color: @cat-text; font-weight: bold; }
      .body { color: @cat-subtext0; }
      .time { color: @cat-overlay0; }

      .notification-action {
        background: @cat-mantle;
        color: @cat-text;
        border: 1px solid @cat-surface0;
        border-radius: 6px;
        margin: 4px;
      }
      .notification-action:hover { background: @cat-surface0; }

      .close-button {
        background: @cat-surface0;
        color: @cat-text;
        border-radius: 100%;
        min-width: 20px;
        min-height: 20px;
        margin: 6px;
      }
      .close-button:hover { background: @cat-red; color: @cat-base; }

      .control-center {
        background: @cat-mantle;
        color: @cat-text;
        border: 1px solid @cat-surface1;
        border-radius: 10px;
      }
      .control-center-list { background: none; }

      .widget-title { color: @cat-text; margin: 10px 10px 4px 10px; }
      .widget-title > label { font-size: ${toString (self.fonts.size + 3)}px; font-weight: bold; }
      .widget-title > button {
        background: @cat-surface0;
        color: @cat-text;
        border: none;
        border-radius: 6px;
        padding: 2px 10px;
      }
      .widget-title > button:hover { background: @cat-surface1; }

      .widget-dnd { color: @cat-text; margin: 4px 10px; }
      .widget-dnd > switch { background: @cat-surface1; border-radius: 12px; }
      .widget-dnd > switch:checked { background: @cat-lavender; }
      .widget-dnd > switch slider { background: @cat-base; border-radius: 12px; }

      .widget-mpris {
        background: @cat-base;
        color: @cat-text;
        border-radius: 8px;
        margin: 6px 10px;
        padding: 6px;
      }
    '';
  in {
    config = lib.mkIf (config.preferences.desktopShell == "waybar") {
      assertions = [
        {
          assertion = !config.home-manager.users.${user}.services.mako.enable;
          message = "swaync and mako are both enabled; import only one notification daemon.";
        }
      ];

      # Auto-DND while screen sharing (xdg-desktop-portal-wlr hooks).
      xdg.portal.wlr.settings.screencast = {
        exec_before = "${screenshareDndOn}";
        exec_after = "${screenshareDndOff}";
      };

      home-manager.users.${user} = {
        home.packages = [pkgs.libnotify dnd dndToggle];

        services.swaync = {
          enable = true;
          package = swaync;
          inherit style;
          settings = {
            positionX = "right";
            positionY = "top";
            layer = "overlay";
            control-center-layer = "top";
            layer-shell = true;
            cssPriority = "user";
            control-center-positionX = "right";
            control-center-positionY = "top";
            control-center-margin-top = 8;
            control-center-margin-bottom = 8;
            control-center-margin-right = 8;
            control-center-width = 380;
            notification-window-width = 360;
            notification-icon-size = 48;
            notification-body-image-height = 100;
            notification-body-image-width = 200;
            timeout = 5;
            timeout-low = 3;
            timeout-critical = 0;
            fit-to-screen = true;
            hide-on-clear = true;
            hide-on-action = true;
            transition-time = 120;
            widgets = ["title" "dnd" "mpris" "notifications"];
            widget-config = {
              title = {
                text = "Notifications";
                clear-all-button = true;
                button-text = "Clear";
              };
              dnd.text = "Do not disturb";
              mpris.image-size = 64;
            };
          };
        };

        # Same startup safety net as waybar: retry instead of condition-skip.
        systemd.user.services.swaync = {
          Unit = {
            ConditionEnvironment = lib.mkForce [];
            StartLimitIntervalSec = 60;
            StartLimitBurst = 30;
          };
          Service.RestartSec = 1;
        };

        # Theme: darkman flips the colors.css symlink and reloads the CSS live.
        home.file = {
          ".config/swaync/catppuccin-latte.css".text = mkColorsCss self.catppuccin;
          ".config/swaync/catppuccin-mocha.css".text = mkColorsCss self.catppuccinMocha;
        };
        home.activation.swayncInitialColors = {
          after = ["writeBoundary"];
          before = [];
          data = ''
            f="$HOME/.config/swaync/colors.css"
            if [ ! -e "$f" ] && [ ! -L "$f" ]; then
              ${pkgs.coreutils}/bin/ln -s "$HOME/.config/swaync/catppuccin-latte.css" "$f"
            fi
          '';
        };
        services.darkman = {
          lightModeScripts.swaync-theme = ''
            ${pkgs.coreutils}/bin/ln -sf "$HOME/.config/swaync/catppuccin-latte.css" "$HOME/.config/swaync/colors.css"
            ${client} -rs >/dev/null 2>&1 || true
          '';
          darkModeScripts.swaync-theme = ''
            ${pkgs.coreutils}/bin/ln -sf "$HOME/.config/swaync/catppuccin-mocha.css" "$HOME/.config/swaync/colors.css"
            ${client} -rs >/dev/null 2>&1 || true
          '';
        };

        # Quiet hours (ported from mako.nix).
        systemd.user.services.dnd-on = {
          Unit.Description = "Enable Do Not Disturb";
          Service = {
            Type = "oneshot";
            ExecStart = "${dnd}/bin/dnd on";
          };
        };
        systemd.user.timers.dnd-on = {
          Unit.Description = "Enable DND at 22:00";
          Timer = {
            OnCalendar = "*-*-* 22:00:00";
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };
        systemd.user.services.dnd-off = {
          Unit.Description = "Disable Do Not Disturb";
          Service = {
            Type = "oneshot";
            ExecStart = "${dnd}/bin/dnd off";
          };
        };
        systemd.user.timers.dnd-off = {
          Unit.Description = "Disable DND at 08:00";
          Timer = {
            OnCalendar = "*-*-* 08:00:00";
            Persistent = true;
          };
          Install.WantedBy = ["timers.target"];
        };

        wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
          "Mod4+Shift+n" = "exec ${client} -t -sw";
        };
      };
    };
  };
}
