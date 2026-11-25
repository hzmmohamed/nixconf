# Headless modes for a laptop carried running (design:
# docs/plans/2026-11-25-headless-modes-design.md). The mode follows two facts,
# re-checked on DRM hotplug, AC plug/unplug, new input devices and at boot:
#
#   desk      external display connected      everything as configured
#   headless  no display, on AC               built-in keyboard/touchpad muted
#   bag       no display, on battery          muted + power-saver + CPU cap
#
# Power key (every mode): short press ignored, long press powers off. Hot
# alert: ntfy push when the CPU package stays hot. Override the power tier
# with `headless-mode auto|bag|full` (until reboot). Core logic and its test:
# headless-modes.sh, headless-modes-test.sh (checks.headless-modes).
{...}: {
  perSystem = {pkgs, ...}: {
    checks.headless-modes =
      pkgs.runCommand "headless-modes-check" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused];
      } ''
        bash ${./headless-modes-test.sh} ${./headless-modes.sh}
        touch $out
      '';
  };

  flake.nixosModules.headless-modes = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.headlessModes;
    ppd = config.services.power-profiles-daemon.enable;
    hot = cfg.hotAlert.enable && cfg.hotAlert.topicFile != null;

    env = {
      HM_INPUT_REGEX = cfg.inputRegex;
      HM_IGNORE_CONNECTORS = lib.concatStringsSep " " cfg.ignoreConnectors;
      HM_BAG_LONG_W = toString cfg.bag.longWatts;
      HM_BAG_SHORT_W = toString cfg.bag.shortWatts;
      HM_FULL_PROFILE = cfg.fullProfile;
      HM_PPD = lib.optionalString ppd (lib.getExe pkgs.power-profiles-daemon);
      HM_HOT_C = toString cfg.hotAlert.celsius;
      HM_HOT_COUNT = "2";
      HM_HOT_COOLDOWN = "900";
      HM_NTFY_TOPIC_FILE = lib.optionalString hot (toString cfg.hotAlert.topicFile);
      HM_CURL = lib.getExe pkgs.curl;
    };

    core = pkgs.writeShellApplication {
      name = "headless-modes-core";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") env)}
        ${builtins.readFile ./headless-modes.sh}
      '';
    };

    cli = pkgs.writeShellApplication {
      name = "headless-mode";
      runtimeInputs = [pkgs.coreutils pkgs.gnused config.systemd.package pkgs.libnotify] ++ lib.optional ppd pkgs.power-profiles-daemon;
      text = ''
        # Root via doas (passwordless for the user) when not root already.
        asroot() { if [ "$(id -u)" = 0 ]; then "$@"; else doas "$@"; fi; }
        set_mode() {
          asroot ${lib.getExe core} set-override "$1"
          asroot systemctl restart headless-mode-apply.service
        }
        status() {
          ${lib.getExe core} detect | sed 's/^/mode: /'
          ${lib.optionalString ppd ''echo "profile: $(powerprofilesctl get)"''}
          for z in /sys/class/powercap/intel-rapl:[0-9]; do
            [ -r "$z/constraint_0_power_limit_uw" ] &&
              echo "cpu cap: $(($(cat "$z/constraint_0_power_limit_uw") / 1000000)) W"
          done
        }
        case "''${1:-status}" in
          auto | bag | full) set_mode "$1" ;;
          toggle)
            case $(cat /run/headless-mode/override 2>/dev/null || true) in
              bag) set_mode auto ;;
              *) set_mode bag ;;
            esac
            ;;
          status) status; exit 0 ;;
          *) echo "usage: headless-mode status|auto|bag|full|toggle" >&2; exit 2 ;;
        esac
        msg=$(status)
        echo "$msg"
        if [ -n "''${WAYLAND_DISPLAY:-}" ] && [ ! -t 1 ]; then
          notify-send -a headless-mode "$(head -n1 <<<"$msg")" "$(tail -n +2 <<<"$msg")" || true
        fi
      '';
    };

    restart = "${config.systemd.package}/bin/systemctl --no-block restart headless-mode-apply.service";
  in {
    options.preferences.headlessModes = {
      enable = lib.mkEnableOption ''
        desk / headless / bag modes from "external display?" and "on AC?":
        built-in keyboard muted when headless, CPU capped on battery, power
        key needs a long press, hot alert'';

      inputRegex = lib.mkOption {
        type = lib.types.str;
        default = "^(AT Translated Set 2 keyboard|Asus WMI hotkeys|.*Touchpad)$";
        description = "Bash regex of /sys/class/input/*/name values muted when headless (USB keyboards must not match).";
      };
      ignoreConnectors = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["eDP-*" "LVDS-*" "DSI-*"];
        description = "Connector globs (without `cardN-`) that never count as an external display.";
      };
      fullProfile = lib.mkOption {
        type = lib.types.str;
        default = "performance";
        description = "power-profiles-daemon profile outside bag mode.";
      };
      bag = {
        longWatts = lib.mkOption {
          type = lib.types.ints.positive;
          default = 15;
          description = "CPU package long-term (RAPL constraint 0) limit in bag mode, W.";
        };
        shortWatts = lib.mkOption {
          type = lib.types.ints.positive;
          default = 25;
          description = "CPU package short-term (RAPL constraint 1) limit in bag mode, W.";
        };
      };
      powerKey.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ignore a short power-key press; a long press powers off.";
      };
      hotAlert = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "ntfy push when the CPU package stays above `celsius` (2 samples 30 s apart, then 15 min quiet).";
        };
        celsius = lib.mkOption {
          type = lib.types.ints.positive;
          default = 90;
          description = "Hot-alert threshold.";
        };
        topicFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = lib.attrByPath ["preferences" "agents" "ntfy" "topicFile"] null config;
          defaultText = lib.literalExpression "config.preferences.agents.ntfy.topicFile or null";
          description = "File holding the ntfy topic or full URL (read as root); null logs to the journal only.";
        };
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        systemd.services.headless-mode-apply = {
          description = "Apply the headless mode (desk / headless / bag)";
          after = lib.optional ppd "power-profiles-daemon.service";
          wants = lib.optional ppd "power-profiles-daemon.service";
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe core} apply";
          };
        };

        # `restart` (not `start`): an event during a run queues a fresh run, so
        # the last state always wins.
        services.udev.extraRules = ''
          ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{HOTPLUG}=="1", RUN+="${restart}"
          ACTION=="change", SUBSYSTEM=="power_supply", RUN+="${restart}"
          ACTION=="add", SUBSYSTEM=="input", KERNEL=="input[0-9]*", RUN+="${restart}"
        '';

        environment.systemPackages =
          [cli]
          ++ lib.optional config.preferences.desktop.enable (pkgs.makeDesktopItem {
            name = "headless-mode";
            desktopName = "Bag mode";
            genericName = "Toggle bag mode";
            comment = "Force bag mode (CPU capped, quiet) or go back to automatic";
            icon = "battery-good";
            exec = "${lib.getExe cli} toggle";
            categories = ["System" "Utility"];
            keywords = ["bag" "backpack" "carry" "power" "headless" "quiet"];
          });
      }

      (lib.mkIf cfg.powerKey.enable {
        services.logind.settings.Login = {
          HandlePowerKey = "ignore";
          HandlePowerKeyLongPress = "poweroff";
        };
      })

      (lib.mkIf cfg.hotAlert.enable {
        systemd.services.headless-mode-hot = {
          description = "Headless mode: CPU hot-alert sample";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe core} hot-check";
          };
        };
        systemd.timers.headless-mode-hot = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "1min";
            OnUnitActiveSec = "30s";
            AccuracySec = "5s";
          };
        };
      })
    ]);
  };
}
