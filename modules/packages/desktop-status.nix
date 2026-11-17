# Small status scripts shared by both desktop shells (waybar custom modules and
# the Noctalia "status" plugin). Each prints one waybar-style JSON object:
#   {"text": "...", "tooltip": "...", "class": "..."}
# An empty "text" means "nothing worth showing" — both bars hide the widget then.
{...}: {
  perSystem = {pkgs, ...}: {
    # Unread mail count. Never touches the network: it only sums the per-account
    # counts that `mail-unread-refresh` (email feature) writes to
    # $XDG_RUNTIME_DIR/mail-unread/<account>.count.
    packages.mail-unread-status = pkgs.writeShellApplication {
      name = "mail-unread-status";
      runtimeInputs = [pkgs.coreutils pkgs.jq];
      text = ''
        dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mail-unread"
        total=0
        tooltip=""
        shopt -s nullglob
        for f in "$dir"/*.count; do
          name=$(basename "$f" .count)
          n=$(head -n1 "$f" 2>/dev/null || true)
          [[ "$n" =~ ^[0-9]+$ ]] || continue
          total=$((total + n))
          tooltip+="$name: $n"$'\n'
        done
        tooltip=''${tooltip%$'\n'}
        if [ "$total" -gt 0 ]; then
          text="$total"
          class="unread"
        else
          text=""
          class="none"
        fi
        jq -cn --arg text "$text" --arg tooltip "''${tooltip:-No unread mail}" --arg class "$class" \
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
  };
}
