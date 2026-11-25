# Server mode: close the lid, put the laptop in a bag, keep it running
# (T3 from the phone over the tailnet). Off by default; the lid suspends as
# usual until it is switched on, and it never outlives the session.
#
#   server-mode.service  user unit holding a logind `handle-lid-switch`
#                        inhibitor (`systemd-inhibit … sleep infinity`).
#                        Only the lid action is blocked: low-battery
#                        suspend/hibernate and explicit suspends still work.
#                        PartOf graphical-session.target: logout ends it, and
#                        there is no lingering, so a reboot does too.
#   polkit rule          lets the primary user take that one inhibitor from
#                        a user unit (outside the session), e.g. over SSH.
#   sway lid binds       lid closed while on: internal panel off (no light or
#                        heat in the bag); lid opened: panel back on.
#   server-mode          on | off | toggle | status | waybar; launcher entries
#                        ("Server mode: …"), bar glyph only while on.
{...}: {
  flake.nixosModules.server-mode = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.serverMode;
    user = config.preferences.user.name;
    tailnet = lib.attrByPath ["preferences" "agents" "tailnetDomain"] null config;
    t3Url = lib.optionalString (tailnet != null) "https://${config.networking.hostName}.${tailnet}/";

    serverMode = pkgs.writeShellApplication {
      name = "server-mode";
      runtimeInputs = [pkgs.systemd pkgs.jq pkgs.libnotify pkgs.sway];
      text = ''
        usage() {
          cat >&2 <<'EOF'
        server-mode — keep running with the lid closed (until off or logout)
          server-mode [toggle]   on / off
          server-mode on|off
          server-mode status
          server-mode waybar     JSON for the bar module (empty while off)
        EOF
          exit 2
        }

        unit=server-mode.service
        output=${lib.escapeShellArg cfg.internalOutput}
        t3_url=${lib.escapeShellArg t3Url}

        is_on() { systemctl --user is-active --quiet "$unit"; }
        refresh_bar() {
          systemctl --user kill --kill-whom=main -s SIGRTMIN+${toString cfg.barSignal} waybar.service >/dev/null 2>&1 || true
        }
        notify() {
          notify-send -a "Server mode" -i network-server -u low \
            -h string:x-canonical-private-synchronous:server-mode "$@" >/dev/null 2>&1 || true
        }
        panel() { swaymsg -q output "$output" power "$1" >/dev/null 2>&1 || true; }

        case "''${1:-toggle}" in
          toggle) if is_on; then exec "$0" off; else exec "$0" on; fi ;;
          on) systemctl --user start "$unit" ;;
          off) systemctl --user stop "$unit" ;;
          status)
            if is_on; then echo "on: lid closed keeps running''${t3_url:+ (T3: $t3_url)}"
            else echo "off: lid closed suspends"; fi
            ;;
          waybar)
            if is_on; then
              jq -cn --arg url "$t3_url" '{text: "󰒋", class: "on", alt: "on",
                tooltip: ("<b>Server mode on</b>: closing the lid keeps it running"
                  + (if $url == "" then "" else "\nT3: " + $url end)
                  + "\n\nClick: off")}'
            else
              echo '{"text": ""}'
            fi
            ;;
          # sway bindswitch: panel off on lid close only while on; always on
          # when opened (harmless when it already is).
          lid-closed) is_on && panel off ;;
          lid-opened) panel on ;;
          # unit hooks
          hook-started)
            refresh_bar
            notify "Server mode on" "Close the lid: it keeps running.''${t3_url:+ T3: $t3_url}"
            ;;
          hook-stopped)
            refresh_bar
            panel on
            systemctl --user is-active --quiet graphical-session.target || exit 0
            notify "Server mode off" "Closing the lid suspends again."
            ;;
          *) usage ;;
        esac
      '';
    };
    serverModeExe = lib.getExe serverMode;
  in {
    options.preferences.serverMode = {
      internalOutput = lib.mkOption {
        type = lib.types.str;
        default = "eDP-1";
        description = "Sway name of the built-in panel, switched off while the lid is closed in server mode.";
      };
      barSignal = lib.mkOption {
        type = lib.types.int;
        readOnly = true;
        default = 14;
        description = "waybar SIGRTMIN+N that refreshes the bar module.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = serverModeExe;
        description = "The `server-mode` command (for the bar).";
      };
    };

    config = {
      environment.systemPackages = [serverMode];

      # Only this action, only for the primary user (stock policy allows it
      # for the active session only; the unit runs outside it).
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.login1.inhibit-handle-lid-switch" &&
              subject.user == "${user}") {
            return polkit.Result.YES;
          }
        });
      '';

      home-manager.users.${user} = {
        systemd.user.services.server-mode = {
          Unit = {
            Description = "Server mode: lid switch ignored";
            PartOf = ["graphical-session.target"];
            After = ["graphical-session.target"];
          };
          Service = {
            Type = "exec";
            ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=handle-lid-switch --who=server-mode --why='Server mode (lid closed, keep running)' --mode=block ${pkgs.coreutils}/bin/sleep infinity";
            ExecStartPost = "${serverModeExe} hook-started";
            ExecStopPost = "${serverModeExe} hook-stopped";
          };
        };

        wayland.windowManager.sway.config.bindswitches = {
          "lid:on" = {
            locked = true;
            reload = false;
            action = "exec ${serverModeExe} lid-closed";
          };
          "lid:off" = {
            locked = true;
            reload = false;
            action = "exec ${serverModeExe} lid-opened";
          };
        };

        # Launcher entries (vicinae lists desktop entries).
        xdg.desktopEntries = lib.mapAttrs (_: e:
          {
            icon = "network-server";
            categories = ["Utility"];
            terminal = false;
          }
          // e) {
          server-mode = {
            name = "Server mode: toggle";
            genericName = "Keep running with the lid closed (T3 from the phone)";
            exec = "${serverModeExe} toggle";
          };
          server-mode-off = {
            name = "Server mode: off";
            genericName = "Closing the lid suspends again";
            exec = "${serverModeExe} off";
          };
        };
      };
    };
  };
}
