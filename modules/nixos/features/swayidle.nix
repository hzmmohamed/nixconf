# Idle, lock and "caffeine" for the Sway desktops.
#
#   swayidle     user service (graphical-session.target):
#                  lockAfter idle       lock-screen        } skipped while
#                  screenOffAfter idle  outputs off        } caffeine is on
#                  activity             outputs on
#                  before-sleep, `loginctl lock-session`   lock-screen (always)
#   lock-screen  swaylock-effects on the current wallpaper (set-wallpaper's
#                state file; palette `surface` when there is none), with an
#                opaque indicator disc: clock + date inside, a ring that
#                lights a segment per key press, verify / wrong / clear /
#                caps-lock states and the keyboard layout while typing. No
#                blur, vignette, screenshot, fade or alpha. Mod4+Escape.
#   caffeine     pauses the idle lock and screen-off (before-sleep and manual
#                locks still work): toggle, for a while, or until a process
#                exits. State = the `caffeine.service` user unit; swayidle is
#                restarted when it ends, so the idle clock starts from then.
#                Mod4+c, vicinae ("Caffeine: …"), the waybar glyph.
#   automatic    sway `inhibit_idle fullscreen` for browsers, video players and
#                games (gamepad input doesn't count as activity).
#
# Audio-based inhibition is deliberately left out: music runs as a daemon, so
# "keep awake while audio plays" would mean "never lock while music plays".
{self, ...}: {
  flake.nixosModules.swayidle = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.idle;
    user = config.preferences.user.name;
    swaymsg = "${pkgs.sway}/bin/swaymsg";
    minutes = s: "${toString (s / 60)} min";
    d = self.design;

    # swaylock has no include directive, so its whole (small, appearance-only)
    # config is rendered per mode and ~/.config/swaylock/config links to the
    # current one. Palette only; the wallpaper comes from lock-screen.
    mkSwaylockConfig = p: let
      c = p.noHash;
      settings = {
        # Background: the wallpaper (--image from lock-screen), else surface.
        color = c.surface;
        scaling = "fill";

        font = d.type.family.ui;
        font-size = d.type.size.display; # clock + layout box; the date is drawn at radius/6

        clock = true;
        timestr = "%H:%M";
        datestr = "%A, %d %B";

        # An always-visible opaque disc: legible on any wallpaper.
        indicator = true;
        indicator-idle-visible = true;
        indicator-radius = d.lock.ringRadius;
        indicator-thickness = d.lock.ringThickness;
        indicator-caps-lock = true;
        show-keyboard-layout = true; # us / ara, shown while typing
        show-failed-attempts = true;
        ignore-empty-password = true;

        inside-color = c.surface;
        inside-clear-color = c.surface;
        inside-caps-lock-color = c.surface;
        inside-ver-color = c.surface;
        inside-wrong-color = c.surface;
        # The line is drawn on both edges of the ring: a surface-coloured rim
        # that separates the ring from the wallpaper.
        line-color = c.surface;
        line-clear-color = c.surface;
        line-caps-lock-color = c.surface;
        line-ver-color = c.surface;
        line-wrong-color = c.surface;
        separator-color = c.surface;

        # Ring states: outline (≥3:1) idle, accent while a key lights a
        # segment / verifying, warning for caps lock, error when wrong.
        ring-color = c.outline; # idle / typing
        ring-clear-color = c.fgFaint; # input cleared
        ring-caps-lock-color = c.warning;
        ring-ver-color = c.accent; # verifying
        ring-wrong-color = c.error;
        key-hl-color = c.accent; # one segment per key press
        bs-hl-color = c.fgMuted;
        caps-lock-key-hl-color = c.warning;
        caps-lock-bs-hl-color = c.fgMuted;

        text-color = c.fg;
        text-clear-color = c.fgMuted;
        text-caps-lock-color = c.warning;
        text-ver-color = c.accentText;
        text-wrong-color = c.error;

        layout-bg-color = c.surface;
        layout-border-color = c.outline;
        layout-text-color = c.fg;
      };
    in
      lib.concatStrings (lib.mapAttrsToList (k: v:
        if v == true
        then "${k}\n"
        else "${k}=${toString v}\n")
      settings);

    lockScreen = pkgs.writeShellApplication {
      name = "lock-screen";
      runtimeInputs = [pkgs.swaylock-effects pkgs.procps pkgs.jq pkgs.coreutils];
      text = ''
        # lock + before-sleep (or a keybind) may fire together: lock once.
        if pgrep -u "$(id -u)" -x swaylock >/dev/null; then exit 0; fi
        args=(-f)
        wallpaper_state="''${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper/current.json"
        img="$(jq -r '.file // empty' "$wallpaper_state" 2>/dev/null || true)"
        if [ -n "$img" ] && [ -r "$img" ]; then args+=(--image "$img"); fi
        exec swaylock "''${args[@]}" "$@"
      '';
    };

    caffeine = pkgs.writeShellApplication {
      name = "caffeine";
      runtimeInputs = [pkgs.systemd pkgs.coreutils pkgs.gnused pkgs.procps pkgs.jq pkgs.libnotify];
      text = ''
        usage() {
          cat >&2 <<'EOF'
        caffeine — pause the idle lock and screen-off (suspend/manual locks still lock)
          caffeine [toggle]       on until turned off / off
          caffeine on [DURATION]  DURATION: 45 | 45m | 1h | 1h30 (default: until off)
          caffeine off
          caffeine pid PID        on until process PID exits
          caffeine run -- CMD...  run CMD, on until it exits
          caffeine status         print the state
          caffeine check          exit 0 while on (used by swayidle)
          caffeine menu           duration picker (vicinae dmenu)
          caffeine waybar         JSON for the bar module
        EOF
          exit 2
        }

        run_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        state="$run_dir/caffeine"
        unit=caffeine.service
        lock_after=${lib.escapeShellArg (minutes cfg.lockAfter)}
        screen_off_after=${lib.escapeShellArg (minutes cfg.screenOffAfter)}

        is_on() { systemctl --user is-active --quiet "$unit"; }
        field() { sed -n "s/^$1=//p" "''${2:-$state}" 2>/dev/null | head -n1; }
        refresh_bar() {
          systemctl --user kill --kill-whom=main -s SIGRTMIN+13 waybar.service >/dev/null 2>&1 || true
        }
        notify() {
          notify-send -a Caffeine -i caffeine -u low \
            -h string:x-canonical-private-synchronous:caffeine "$@" >/dev/null 2>&1 || true
        }
        esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

        # Minutes -> "45 min" | "1 h" | "1 h 30".
        human() {
          local m="$1"
          if [ "$m" -lt 60 ]; then echo "$m min"
          elif [ $((m % 60)) -eq 0 ]; then echo "$((m / 60)) h"
          else echo "$((m / 60)) h $((m % 60)) min"; fi
        }
        short() {
          local m="$1"
          if [ "$m" -lt 60 ]; then echo "''${m}m"
          elif [ $((m % 60)) -eq 0 ]; then echo "$((m / 60))h"
          else printf '%dh%02d\n' $((m / 60)) $((m % 60)); fi
        }
        parse_duration() {
          local d="''${1,,}"
          if [[ $d =~ ^([0-9]+)(m|min)?$ ]]; then
            echo $((10#''${BASH_REMATCH[1]} * 60))
          elif [[ $d =~ ^([0-9]+)h(([0-9]+)(m|min)?)?$ ]]; then
            echo $((10#''${BASH_REMATCH[1]} * 3600 + 10#''${BASH_REMATCH[3]:-0} * 60))
          else
            echo "caffeine: bad duration '$1' (e.g. 45, 45m, 1h, 1h30)" >&2
            exit 2
          fi
        }

        # request KIND VALUE LABEL — (re)start the unit with a new request.
        # The pending file tells the stop hook that this is a replacement.
        request() {
          mkdir -p "$run_dir"
          {
            echo "kind=$1"
            echo "value=$2"
            echo "label=$3"
            if [ "$1" = seconds ]; then echo "until=$(($(date +%s) + $2))"; fi
          } >"$state.next"
          systemctl --user restart "$unit"
        }

        describe() { # human description of the running request
          local kind value label until left
          kind="$(field kind)"
          value="$(field value)"
          label="$(field label)"
          case "$kind" in
            seconds)
              until="$(field until)"
              left=$(((until - $(date +%s) + 59) / 60))
              [ "$left" -ge 1 ] || left=1
              echo "for $(human "$left") more (until $(date -d "@$until" +%H:%M))"
              ;;
            pid) echo "until $label (PID $value) exits" ;;
            *) echo "until turned off" ;;
          esac
        }

        cmd_on() {
          if [ -z "''${1:-}" ]; then
            request infinity 0 ""
          else
            local s
            s="$(parse_duration "$1")"
            [ "$s" -gt 0 ] || { echo "caffeine: duration must be > 0" >&2; exit 2; }
            request seconds "$s" ""
          fi
        }

        cmd_pid() {
          local pid="''${1:-}" name
          [[ $pid =~ ^[0-9]+$ ]] || usage
          name="$(ps -o comm= -p "$pid" 2>/dev/null)" || { echo "caffeine: no process $pid" >&2; exit 1; }
          request pid "$pid" "$name"
        }

        cmd_off() { systemctl --user stop "$unit"; }

        cmd_toggle() { if is_on; then cmd_off; else cmd_on; fi; }

        cmd_status() {
          if is_on; then echo "on: $(describe)"; else echo "off (lock after $lock_after idle, screen off after $screen_off_after)"; fi
        }

        cmd_menu() {
          local opts=() choice
          if is_on; then opts+=("Turn off ($(describe))"); fi
          opts+=("Keep awake until turned off" "30 minutes" "1 hour" "2 hours" "4 hours")
          read -ra launcher <<<"''${CAFFEINE_MENU_LAUNCHER:-vicinae dmenu -p Caffeine --no-quick-look}"
          choice="$(printf '%s\n' "''${opts[@]}" | "''${launcher[@]}")" || exit 0
          case "$choice" in
            "Turn off"*) cmd_off ;;
            "Keep awake"*) cmd_on ;;
            "30 minutes") cmd_on 30m ;;
            "1 hour") cmd_on 1h ;;
            "2 hours") cmd_on 2h ;;
            "4 hours") cmd_on 4h ;;
            *) exit 0 ;;
          esac
        }

        cmd_waybar() {
          local text tooltip class value="" kind left
          if is_on; then
            class=on
            text="󰅶"
            kind="$(field kind)"
            if [ "$kind" = seconds ]; then
              left=$((($(field until) - $(date +%s) + 59) / 60))
              [ "$left" -ge 1 ] || left=1
              value="$(short "$left")"
            fi
            tooltip="<b>Caffeine on</b>: no idle lock or screen-off $(describe | esc)"
          else
            class=off
            text="󰛊"
            tooltip="<b>Caffeine off</b>: locks after $lock_after idle, screen off after $screen_off_after"
          fi
          [ -z "$value" ] || text="$text"$'\n'"<span size='small'>$value</span>"
          tooltip="$tooltip"$'\n\n'"Click: toggle · Right-click: for a while…"
          jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$class" \
            '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
        }

        # --- unit internals (caffeine.service) ---
        hook_start() { # ExecStartPre: adopt the pending request
          if [ -e "$state.next" ]; then mv -f "$state.next" "$state"; else rm -f "$state"; fi
        }
        hook_started() { # ExecStartPost
          refresh_bar
          notify "Caffeine on" "No idle lock or screen-off $(describe)."
        }
        hold() { # ExecStart
          case "$(field kind)" in
            seconds) exec sleep "$(field value)" ;;
            pid) exec tail --pid="$(field value)" -f /dev/null ;;
            *) exec sleep infinity ;;
          esac
        }
        hook_stopped() { # ExecStopPost
          [ -e "$state.next" ] && exit 0 # replaced by a new request
          rm -f "$state"
          refresh_bar
          # Logout: the session is going away; nothing to tell or restart.
          systemctl --user is-active --quiet graphical-session.target || exit 0
          # Restart the idle clock: lock after the full timeout from now.
          systemctl --user --no-block try-restart swayidle.service || true
          notify "Caffeine off" "Idle lock is back: locks after $lock_after idle."
        }

        case "''${1:-toggle}" in
          toggle) cmd_toggle ;;
          on) cmd_on "''${2:-}" ;;
          off) cmd_off ;;
          pid) cmd_pid "''${2:-}" ;;
          run)
            shift
            [ "''${1:-}" = -- ] && shift
            [ $# -gt 0 ] || usage
            request pid "$$" "$(basename "$1")"
            exec "$@" # same PID: caffeine ends when CMD does
            ;;
          status) cmd_status ;;
          check) is_on ;;
          menu) cmd_menu ;;
          waybar) cmd_waybar ;;
          hook-start) hook_start ;;
          hook-started) hook_started ;;
          hold) hold ;;
          hook-stopped) hook_stopped ;;
          *) usage ;;
        esac
      '';
    };

    caffeineExe = lib.getExe caffeine;
    lockExe = lib.getExe lockScreen;

    # swayidle runs these through sh; small scripts keep systemd's ExecStart
    # free of nested quoting.
    idleLock = pkgs.writeShellScript "idle-lock" ''
      ${caffeineExe} check && exit 0
      exec ${lockExe}
    '';
    idleScreenOff = pkgs.writeShellScript "idle-screen-off" ''
      ${caffeineExe} check && exit 0
      exec ${swaymsg} 'output * power off'
    '';
    idleScreenOn = pkgs.writeShellScript "idle-screen-on" ''
      exec ${swaymsg} 'output * power on'
    '';

    # Fullscreen windows of these apps keep the session awake.
    fullscreenInhibit = [
      {app_id = "^(firefox|chromium-browser|chromium|mpv|vlc|org.videolan.VLC|io.github.celluloid_player.Celluloid|gamescope)$";}
      {class = "^(Chromium|chromium-browser|mpv|vlc|steam_app_.*|gamescope)$";}
    ];
  in {
    options.preferences.idle = {
      lockAfter = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = "Seconds of inactivity before the screen locks.";
      };
      screenOffAfter = lib.mkOption {
        type = lib.types.ints.positive;
        default = 600;
        description = "Seconds of inactivity before the outputs are powered off.";
      };
      caffeineCommand = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = caffeineExe;
        description = "The `caffeine` command (for the bar).";
      };
      lockCommand = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = lockExe;
        description = "The `lock-screen` command.";
      };
    };

    config = {
      environment.systemPackages = [pkgs.swaylock-effects pkgs.swayidle lockScreen caffeine];

      preferences.theme = {
        files."swaylock.conf" = mkSwaylockConfig;
        links.".config/swaylock/config" = "swaylock.conf";
      };

      home-manager.users.${user} = {
        services.swayidle = {
          enable = true;
          timeouts = [
            {
              timeout = cfg.lockAfter;
              command = "${idleLock}";
            }
            {
              timeout = cfg.screenOffAfter;
              command = "${idleScreenOff}";
              resumeCommand = "${idleScreenOn}";
            }
          ];
          events = {
            before-sleep = lockExe;
            lock = lockExe;
          };
        };

        systemd.user.services = {
          swayidle = {
            # Same safety net as waybar: retry instead of a condition skip.
            Unit = {
              ConditionEnvironment = lib.mkForce [];
              StartLimitIntervalSec = 60;
              StartLimitBurst = 30;
            };
            Service = {
              RestartSec = 1;
              # swaylock (forked by swayidle) must survive a swayidle restart:
              # killing it would leave the session stuck behind sway's
              # "lock client died" screen.
              KillMode = "process";
            };
          };

          caffeine = {
            Unit = {
              Description = "Caffeine: idle lock and screen-off paused";
              PartOf = ["graphical-session.target"];
              After = ["graphical-session.target"];
            };
            Service = {
              Type = "exec";
              ExecStartPre = "${caffeineExe} hook-start";
              ExecStart = "${caffeineExe} hold";
              ExecStartPost = "${caffeineExe} hook-started";
              ExecStopPost = "${caffeineExe} hook-stopped";
            };
          };
        };

        # Launcher entries (vicinae lists desktop entries).
        xdg.desktopEntries = lib.mapAttrs (_: e:
          {
            icon = "caffeine";
            categories = ["Utility"];
            terminal = false;
          }
          // e) {
          caffeine = {
            name = "Caffeine: keep awake";
            genericName = "Toggle the idle lock";
            exec = "${caffeineExe} toggle";
          };
          caffeine-30m = {
            name = "Caffeine: 30 minutes";
            exec = "${caffeineExe} on 30m";
          };
          caffeine-1h = {
            name = "Caffeine: 1 hour";
            exec = "${caffeineExe} on 1h";
          };
          caffeine-2h = {
            name = "Caffeine: 2 hours";
            exec = "${caffeineExe} on 2h";
          };
          caffeine-off = {
            name = "Caffeine: off";
            genericName = "Idle lock back on";
            exec = "${caffeineExe} off";
          };
        };

        wayland.windowManager.sway.config = {
          keybindings = lib.mkOptionDefault {
            "Mod4+Escape" = "exec ${lockExe}";
            "Mod4+c" = "exec ${caffeineExe} toggle";
          };
          window.commands =
            map (criteria: {
              inherit criteria;
              command = "inhibit_idle fullscreen";
            })
            fullscreenInhibit;
        };
      };
    };
  };
}
