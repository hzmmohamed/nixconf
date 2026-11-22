# Small status scripts shared by both desktop shells (waybar custom modules and
# the Noctalia "status" plugin). Each prints one waybar-style JSON object:
#   {"text": "...", "tooltip": "...", "class": "..."}
# An empty "text" means "nothing worth showing" — both bars hide the widget then.
{...}: {
  perSystem = {pkgs, ...}: {
    # Unread mail, one entry per account ("P 3", "W 12": the account name's
    # initial and its count). Never touches the network: it only reads the
    # per-account counts that `mail-unread-refresh` (email feature) writes to
    # $XDG_RUNTIME_DIR/mail-unread/<account>.count. Always shows something
    # (the widget is also the mail menu): "–" before the first refresh.
    #   --markup  one account per line, zero counts dimmed (pango, waybar);
    #             default: one line, "P3 W12" (plain text, Noctalia)
    packages.mail-unread-status = pkgs.writeShellApplication {
      name = "mail-unread-status";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text = ''
        markup=false
        [ "''${1:-}" = --markup ] && markup=true
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mail-unread"
        total=0
        entries=()
        tooltip=""
        shopt -s nullglob
        for f in "$dir"/*.count; do
          name=$(basename "$f" .count)
          n=$(head -n1 "$f" 2>/dev/null || true)
          [[ "$n" =~ ^[0-9]+$ ]] || continue
          total=$((total + n))
          entry="''${name:0:1}"
          entry="''${entry^}"
          if ! $markup; then
            entry+="$n"
          elif [ "$n" -eq 0 ]; then
            entry="<span alpha='45%'>$entry $n</span>"
          else
            entry+=" $n"
          fi
          entries+=("$entry")
          tooltip+="$name: $n"$'\n'
        done
        tooltip=''${tooltip%$'\n'}
        if [ "''${#entries[@]}" -eq 0 ]; then
          text="–"
        elif $markup; then
          text=$(printf '%s\n' "''${entries[@]}")
        else
          text="''${entries[*]}"
        fi
        if [ "$total" -gt 0 ]; then class="unread"; else class="none"; fi
        jq -cn --arg text "$text" --arg tooltip "''${tooltip:-No counts yet}" --arg class "$class" \
          '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
      '';
    };

    # Syncthing state via its local REST API. The API key is read from the
    # user-owned config.xml (Syncthing generates it; nothing secret enters the
    # Nix store). Shows nothing while everything is in sync.
    #   SYNCTHING_CONFIG_DIR  (default ~/.config/syncthing)
    #   SYNCTHING_ADDRESS     (default 127.0.0.1:8384)
    packages.sync-status = pkgs.writeShellApplication {
      name = "sync-status";
      runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.jq pkgs.gnugrep pkgs.gnused];
      text = ''
        cfgdir="''${SYNCTHING_CONFIG_DIR:-$HOME/.config/syncthing}"
        addr="''${SYNCTHING_ADDRESS:-127.0.0.1:8384}"

        emit() {
          jq -cn --arg text "$1" --arg tooltip "$2" --arg class "$3" \
            '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
          exit 0
        }

        key=$(grep -o '<apikey>[^<]*</apikey>' "$cfgdir/config.xml" 2>/dev/null \
          | sed -e 's/<[^>]*>//g' || true)
        [ -n "$key" ] || emit "!" "Syncthing: no API key found in $cfgdir/config.xml" "down"

        api() {
          curl -fsS --max-time 3 -H "X-API-Key: $key" "http://$addr/rest/$1"
        }

        completion=$(api "db/completion") || emit "!" "Syncthing is not reachable on $addr" "down"
        errors=$(api "system/error" | jq -r '(.errors // []) | length' 2>/dev/null || echo 0)
        connected=$(api "system/connections" \
          | jq -r '[.connections[] | select(.connected)] | length' 2>/dev/null || echo "?")

        pct=$(jq -r '.completion | floor' <<<"$completion")
        need_items=$(jq -r '.needItems + .needDeletes' <<<"$completion")
        need_mb=$(jq -r '(.needBytes / 1048576) | floor' <<<"$completion")

        if [ "$errors" != "0" ]; then
          emit "!" "Syncthing: $errors error(s) — open the web UI" "error"
        elif [ "$need_items" != "0" ]; then
          emit "$pct%" "Syncing: $need_items item(s), $need_mb MiB left · $connected device(s) connected" "syncing"
        else
          emit "" "In sync · $connected device(s) connected" "idle"
        fi
      '';
    };

    # Coding-agent sessions. Claude Code hooks keep one file per session in
    # $XDG_RUNTIME_DIR/agent-status/ (line 1: working|input|done, line 2:
    # optional project name; removed on session end) and nudge waybar with
    # SIGRTMIN+10. `done` files older than 10 min count as idle.
    #   agent-status busy     working count, else count of recent `done`
    #   agent-status working  working count only
    #   agent-status input    sessions waiting for the user
    # text = the count (empty = hide); alt/class = working|done|input|idle.
    packages.agent-status = pkgs.writeShellApplication {
      name = "agent-status";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text = ''
        mode=''${1:-busy}
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-status"
        now=$(date +%s)
        working=0
        input=0
        recent=0
        tooltip=""
        shopt -s nullglob
        for f in "$dir"/*; do
          [ -f "$f" ] || continue
          lines=()
          mapfile -t -n 2 lines 2>/dev/null <"$f" || continue
          state=''${lines[0]:-}
          state=''${state//[[:space:]]/}
          project=''${lines[1]:-}
          [ -n "$project" ] || project=$(basename "$f")
          case "$state" in
            working) working=$((working + 1)) ;;
            input) input=$((input + 1)) ;;
            "done")
              mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
              [ $((now - mtime)) -lt 600 ] || continue
              recent=$((recent + 1))
              ;;
            *) continue ;;
          esac
          tooltip+="$project · $state"$'\n'
        done
        tooltip=''${tooltip%$'\n'}

        text=""
        class="idle"
        case "$mode" in
          busy)
            if [ "$working" -gt 0 ]; then
              text=$working class=working
            elif [ "$recent" -gt 0 ]; then
              text=$recent class="done"
            fi
            ;;
          working) [ "$working" -eq 0 ] || { text=$working class=working; } ;;
          input) [ "$input" -eq 0 ] || { text=$input class=input; } ;;
          *)
            echo "usage: agent-status [busy|working|input]" >&2
            exit 2
            ;;
        esac
        jq -cn --arg text "$text" --arg tooltip "''${tooltip:-No agent sessions}" --arg class "$class" \
          '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
      '';
    };

    # Nix daemon activity. Local builds run as build users (nixbld<N>, or
    # uids >= 872415232 with auto-allocate-uids): one distinct uid per running
    # build. Substitutions/copies run inside the per-client daemon workers
    # (children of the main nix-daemon), so a worker without builds = "busy".
    # text = build count, else worker count; class = build|busy|idle.
    packages.nix-build-status = pkgs.writeShellApplication {
      name = "nix-build-status";
      runtimeInputs = [pkgs.procps pkgs.gawk pkgs.jq];
      text = ''
        builds=$(ps -eo uid=,user= | awk '$2 ~ /^nixbld[0-9]+$/ || $1 >= 872415232 { u[$1] = 1 } END { print length(u) }')
        workers=0
        main=$(pgrep -o -x nix-daemon || true)
        if [ -n "$main" ]; then
          workers=$(pgrep -c -P "$main" || true)
        fi
        workers=''${workers:-0}

        if [ "$builds" -gt 0 ]; then
          text=$builds class=build
        elif [ "$workers" -gt 0 ]; then
          text=$workers class=busy
        else
          text="" class=idle
        fi
        jq -cn --arg text "$text" --arg class "$class" \
          --arg tooltip "Nix: $builds build(s) · $workers daemon client(s)" \
          '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
      '';
    };

    # Root filesystem free space with absolute thresholds (percent is noise on
    # a big disk). Hidden at >= DISK_FREE_WARN_GB GiB free (default 100);
    # class warning below it, critical below DISK_FREE_CRIT_GB (default 30).
    #   disk-free-status [path]   (default /)
    packages.disk-free-status = pkgs.writeShellApplication {
      name = "disk-free-status";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text = ''
        path=''${1:-/}
        warn=$((''${DISK_FREE_WARN_GB:-100} * 1073741824))
        crit=$((''${DISK_FREE_CRIT_GB:-30} * 1073741824))
        read -r size used avail < <(df -B1 --output=size,used,avail "$path" | tail -n1)
        h() { numfmt --to=iec --format=%.1f "$1"; }
        tooltip="$path: $(h "$used") used · $(h "$avail") free · $(h "$size") total"
        if [ "$avail" -lt "$crit" ]; then
          text=$(numfmt --to=iec "$avail") class=critical
        elif [ "$avail" -lt "$warn" ]; then
          text=$(numfmt --to=iec "$avail") class=warning
        else
          text="" class=ok
        fi
        jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$class" \
          '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
      '';
    };

    # Camera in use: any process holding /dev/video* open (V4L2 apps such as
    # browsers bypass PipeWire, so waybar's privacy module misses them).
    # Only the user's own processes are visible, which is what matters here.
    packages.camera-status = pkgs.writeShellApplication {
      name = "camera-status";
      runtimeInputs = [pkgs.coreutils pkgs.findutils pkgs.jq];
      text = ''
        apps=""
        shopt -s nullglob
        cams=(/dev/video*)
        if [ "''${#cams[@]}" -gt 0 ]; then
          while IFS= read -r fd; do
            pid=''${fd#/proc/}
            pid=''${pid%%/*}
            comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
            case "$comm" in pipewire | wireplumber | "") continue ;; esac
            case " $apps " in *" $comm "*) ;; *) apps+="''${apps:+ }$comm" ;; esac
          done < <(find /proc/[0-9]*/fd -lname '/dev/video*' 2>/dev/null || true)
        fi
        if [ -n "$apps" ]; then
          text=on class=active tooltip="Camera: $apps"
        else
          text="" class=idle tooltip="Camera idle"
        fi
        jq -cn --arg text "$text" --arg tooltip "$tooltip" --arg class "$class" \
          '{text: $text, tooltip: $tooltip, class: $class, alt: $class}'
      '';
    };
  };
}
