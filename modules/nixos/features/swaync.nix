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
    swaync = pkgs.swaynotificationcenter;
    client = "${swaync}/bin/swaync-client";

    theme = config.preferences.theme;

    # Palette-only CSS, included from the theme state dir.
    mkColorsCss = p: ''
      @define-color surface ${p.surface};
      @define-color surface-low ${p.surfaceContainerLow};
      @define-color surface-container ${p.surfaceContainer};
      @define-color outline-variant ${p.outlineVariant};
      @define-color fg ${p.fg};
      @define-color fg-muted ${p.fgMuted};
      @define-color fg-faint ${p.fgFaint};
      @define-color inverse ${p.inverseSurface};
      @define-color on-inverse ${p.onInverseSurface};
      @define-color accent ${p.accent};
      @define-color error ${p.error};
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
      @import url("file://${theme.stateDir}/current/swaync.css");

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
        background: @surface;
        color: @fg;
        border: 1px solid @outline-variant;
        border-radius: 8px;
        margin: 6px;
        padding: 0;
        box-shadow: none;
      }
      .notification.critical { border-color: @error; }
      .notification-content { padding: 10px; }
      .summary { color: @fg; font-weight: bold; }
      .body { color: @fg-muted; }
      .time { color: @fg-faint; }

      .notification-action {
        background: @surface-low;
        color: @fg;
        border: 1px solid @surface-container;
        border-radius: 6px;
        margin: 4px;
      }
      .notification-action:hover { background: @surface-container; }

      .close-button {
        background: @surface-container;
        color: @fg;
        border-radius: 100%;
        min-width: 20px;
        min-height: 20px;
        margin: 6px;
      }
      .close-button:hover { background: @error; color: @surface; }

      .control-center {
        background: @surface-low;
        color: @fg;
        border: 1px solid @outline-variant;
        border-radius: 8px;
        box-shadow: none;
      }
      .control-center-list { background: none; }

      .widget-title { color: @fg; margin: 10px 10px 4px 10px; }
      .widget-title > label { font-size: ${toString (self.fonts.size + 3)}px; font-weight: bold; }
      .widget-title > button {
        background: @surface-container;
        color: @fg;
        border: none;
        border-radius: 6px;
        padding: 2px 10px;
      }
      .widget-title > button:hover { background: @outline-variant; }

      .widget-dnd { color: @fg; margin: 4px 10px; }
      .widget-dnd > switch { background: @outline-variant; border-radius: 12px; }
      .widget-dnd > switch:checked { background: @inverse; }
      .widget-dnd > switch slider { background: @surface; border-radius: 12px; }
      .widget-dnd > switch:checked slider { background: @on-inverse; }

      .widget-mpris {
        background: @surface;
        color: @fg;
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

      preferences.theme = {
        files."swaync.css" = mkColorsCss;
        reloadHooks.swaync = "${client} -rs >/dev/null 2>&1 || true";
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
