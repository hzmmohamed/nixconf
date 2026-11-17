# Idle auto-stop for on-demand cloud boxes (fern; design:
# docs/plans/2026-11-17-aws-agent-host.md §3). A root timer marks the box
# busy when any of these holds:
#   - an agent session is `working` (agent-common's agent-status files,
#     younger than `statusMaxAgeHours`; `input`/`done` count as idle)
#   - the user slice + nix-daemon used more than `cpuPercent` % of one core
#     on average since the last check (long tool runs, builds)
#   - a terminal of the user (SSH, zellij pane, T3 terminal) had input
#     within `sessionIdleMinutes` (pty atime, like `w`)
#   - a T3 Code tab is open (established TCP to 127.0.0.1:`t3Port`, the
#     Tailscale Serve websocket)
#   - `cloud-idle hold <minutes>` is in effect
# After `idleMinutes` without busy (counted from boot on a fresh start) it
# sends an `agent-notify` (ntfy when configured) and powers off. With the EC2
# shutdown behaviour `stop`, that leaves a stopped instance.
#
# `cloud-idle status` prints the signals; `cloud-idle check` is the timer's job.
{...}: {
  flake.nixosModules.cloud-idle-stop = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.cloudIdleStop;
    user = config.preferences.user.name;

    cloudIdle = pkgs.writeShellApplication {
      name = "cloud-idle";
      runtimeInputs = with pkgs; [coreutils gawk gnugrep gnused iproute2 systemd findutils];
      text = ''
        state=/run/cloud-idle
        idle_min=${toString cfg.idleMinutes}
        cpu_pct=${toString cfg.cpuPercent}
        sess_min=${toString cfg.sessionIdleMinutes}
        status_max_h=${toString cfg.statusMaxAgeHours}
        t3_port=${toString cfg.t3Port}
        user=${lib.escapeShellArg user}

        now=$(date +%s)
        uid=$(id -u "$user" 2>/dev/null || echo "")

        # Each signal prints a reason when busy.
        sig_agents() {
          [ -n "$uid" ] || return 0
          local dir=/run/user/$uid/agent-status n
          [ -d "$dir" ] || return 0
          n=$(find "$dir" -maxdepth 1 -type f ! -name '*.tmp' -mmin "-$((status_max_h * 60))" \
            -exec head -n1 {} \; 2>/dev/null | grep -cx working || true)
          [ "''${n:-0}" -gt 0 ] && echo "agents working: $n"
          return 0
        }

        cpu_usec() {
          local total=0 f v
          for f in "/sys/fs/cgroup/user.slice/user-$uid.slice/cpu.stat" \
            /sys/fs/cgroup/system.slice/nix-daemon.service/cpu.stat; do
            [ -r "$f" ] || continue
            v=$(awk '$1 == "usage_usec" {print $2}' "$f")
            total=$((total + ''${v:-0}))
          done
          echo "$total"
        }

        sig_cpu() {
          [ -n "$uid" ] || return 0
          local cur prev prev_t dt used pct
          cur=$(cpu_usec)
          if [ -r "$state/cpu" ]; then
            read -r prev prev_t <"$state/cpu" || true
            dt=$((now - ''${prev_t:-now}))
            if [ "$dt" -gt 0 ] && [ -n "''${prev:-}" ]; then
              used=$((cur - prev))
              pct=$((used / dt / 10000))
              [ "$pct" -ge "$cpu_pct" ] && echo "cpu: $pct% of a core"
            fi
          fi
          [ "''${1:-}" = record ] && echo "$cur $now" >"$state/cpu"
          return 0
        }

        # Terminals owned by the user (SSH, zellij panes, T3 terminals): the
        # pty's atime is its last input, as in `w`'s IDLE column.
        sig_sessions() {
          local tty age
          for tty in /dev/pts/[0-9]*; do
            [ -e "$tty" ] && [ "$(stat -c %U "$tty")" = "$user" ] || continue
            age=$(( (now - $(stat -c %X "$tty")) / 60 ))
            [ "$age" -lt "$sess_min" ] && echo "terminal ''${tty#/dev/} input ''${age}m ago"
          done
          return 0
        }

        sig_t3() {
          local n
          n=$(ss -Htn state established "( sport = :$t3_port )" 2>/dev/null | wc -l)
          [ "$n" -gt 0 ] && echo "T3 connections: $n"
          return 0
        }

        sig_hold() {
          local hold_until
          [ -r "$state/hold-until" ] || return 0
          hold_until=$(cat "$state/hold-until")
          [ "$hold_until" -gt "$now" ] && echo "hold for $(( (hold_until - now) / 60 ))m"
          return 0
        }

        reasons() {
          sig_hold
          sig_agents
          sig_cpu "''${1:-}"
          sig_sessions
          sig_t3
        }

        mkdir -p "$state"
        # Fresh boot: the idle clock starts now.
        [ -r "$state/last-busy" ] || echo "$now" >"$state/last-busy"

        case "''${1:-status}" in
          check)
            r=$(reasons record)
            if [ -n "$r" ]; then
              echo "$now" >"$state/last-busy"
              echo "busy: $(echo "$r" | paste -sd ';' -)"
              exit 0
            fi
            idle=$(( (now - $(cat "$state/last-busy")) / 60 ))
            echo "idle for ''${idle}m (limit ''${idle_min}m)"
            if [ "$idle" -ge "$idle_min" ]; then
              notify=/etc/profiles/per-user/$user/bin/agent-notify
              if [ -x "$notify" ]; then
                "$notify" "$(uname -n): stopping" "idle for ''${idle}m, powering off" || true
              fi
              systemctl poweroff
            fi
            ;;
          status)
            r=$(reasons)
            idle=$(( (now - $(cat "$state/last-busy")) / 60 ))
            if [ -n "$r" ]; then echo "busy"; printf '%s\n' "$r" | awk '{print "  " $0}'; else echo "idle"; fi
            echo "  last busy ''${idle}m ago; stops after ''${idle_min}m idle"
            ;;
          hold)
            mins=''${2:?usage: cloud-idle hold <minutes>}
            rm -f "$state/hold-until"
            echo $((now + mins * 60)) >"$state/hold-until"
            echo "holding for ''${mins}m"
            ;;
          *)
            echo "usage: cloud-idle [status|check|hold <minutes>]" >&2
            exit 2
            ;;
        esac
      '';
    };
  in {
    options.preferences.cloudIdleStop = {
      idleMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 45;
        description = "Power off after this many minutes without any busy signal.";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = "How often the check runs (systemd time span).";
      };
      cpuPercent = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "Average CPU (percent of one core) of the user slice + nix-daemon that counts as busy.";
      };
      sessionIdleMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "A terminal of the user with input more recent than this counts as busy.";
      };
      statusMaxAgeHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 12;
        description = "Ignore `working` agent-status files older than this (crashed sessions).";
      };
      t3Port = lib.mkOption {
        type = lib.types.port;
        default = 3773;
        description = "Loopback port of the T3 Code server (open tabs keep the box up).";
      };
    };

    config = {
      environment.systemPackages = [cloudIdle];

      # `cloud-idle hold`/`status` also run as the user (`cloud-box hold`
      # over SSH): the state dir is group-writable for wheel.
      systemd.tmpfiles.rules = [
        "d /run/cloud-idle 0775 root wheel - -"
      ];

      systemd.services.cloud-idle-stop = {
        description = "Power off the cloud box when idle";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe cloudIdle} check";
        };
      };

      systemd.timers.cloud-idle-stop = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = cfg.interval;
          OnUnitActiveSec = cfg.interval;
          AccuracySec = "30s";
        };
      };
    };
  };
}
