{self, ...}: {
  flake.nixosModules.kdeconnect = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    kdeconnect = config.home-manager.users.${user}.services.kdeconnect.package;

    # kdeconnectd announces itself (broadcast + `customDevices`, i.e. the
    # phone's tailnet IP) only at start and on a network change. When the
    # phone's Tailscale idles out and comes back, or the TCP link dies, nobody
    # reconnects until a manual refresh. Re-announce while a paired device is
    # unreachable: a few UDP packets, and nothing at all once it's connected.
    reconnect = pkgs.writeShellApplication {
      name = "kdeconnect-reconnect";
      runtimeInputs = [kdeconnect pkgs.coreutils];
      text = ''
        paired=$(kdeconnect-cli --list-devices --id-only 2>/dev/null | sort)
        reachable=$(kdeconnect-cli --list-available --id-only 2>/dev/null | sort)
        if [ -n "$(comm -23 <(echo "$paired") <(echo "$reachable"))" ]; then
          kdeconnect-cli --refresh
        fi
      '';
    };

    # The phone's name in the hosts registry (its tailnet name), for labels.
    phoneName =
      (lib.findFirst (h: lib.elem "phone" (h.roles or [])) {} (lib.attrValues self.hosts)).tailnetName or "phone";
    hasVicinae = config.home-manager.users.${user}.programs.vicinae.enable or false;

    # send-to-phone — push text or an image to the first reachable paired
    # phone. KDE Connect for Android copies shared text to the phone's
    # clipboard; images land in its downloads.
    #   send-to-phone           the current clipboard (text, else an image)
    #   send-to-phone --pick    pick a text entry from vicinae's clipboard history
    #   SEND_TO_PHONE_LAUNCHER  dmenu command for --pick
    #                           default: vicinae dmenu -p "Send to <phone>"
    # --pick reads vicinae 0.23's store read-only: clipboard.db for the list,
    # clipboard-data/<offer id> for the full text (unencrypted entries only).
    sendToPhone = pkgs.writeShellApplication {
      name = "send-to-phone";
      runtimeInputs = [kdeconnect pkgs.systemd pkgs.wl-clipboard pkgs.libnotify pkgs.sqlite pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gawk];
      text = ''
        label=${lib.escapeShellArg phoneName}
        tmp=''${XDG_RUNTIME_DIR:-/tmp}/send-to-phone
        mkdir -p "$tmp"
        # Shares are sent asynchronously: keep temp files for a while.
        find "$tmp" -type f -mmin +60 -delete 2>/dev/null || true

        notify() { notify-send -a "KDE Connect" -i kdeconnect "$@" || true; }

        phone() {
          local id
          for id in $(kdeconnect-cli --list-available --id-only 2>/dev/null); do
            if [ "$(busctl --user get-property org.kde.kdeconnect "/modules/kdeconnect/devices/$id" \
              org.kde.kdeconnect.device type 2>/dev/null)" = 's "phone"' ]; then
              echo "$id"
              return 0
            fi
          done
          return 1
        }

        device=$(phone) || {
          kdeconnect-cli --refresh >/dev/null 2>&1 || true
          sleep 3
          device=$(phone) || {
            notify "$label isn't reachable" "Nothing was sent. Is KDE Connect running on the phone?"
            exit 1
          }
        }

        # Text over ~128 KiB doesn't fit in one argv string: send it as a file.
        send_text() {
          if [ "$(printf %s "$1" | wc -c)" -gt 100000 ]; then
            local f
            f=$(mktemp "$tmp/clipboard-XXXXXX.txt")
            printf %s "$1" >"$f"
            send_file "$f" "Text file ($(wc -c <"$f") bytes)"
            return
          fi
          kdeconnect-cli --device "$device" --share-text="$1" >/dev/null
          notify "Sent to $label" "$(printf %s "$1" | head -c 120)"
        }

        send_file() {
          kdeconnect-cli --device "$device" --share="$1" >/dev/null
          notify "Sent to $label" "$2"
        }

        if [ "''${1:-}" = "--pick" ]; then
          if [ -n "''${SEND_TO_PHONE_LAUNCHER:-}" ]; then
            read -ra launcher <<<"$SEND_TO_PHONE_LAUNCHER"
          else
            launcher=(vicinae dmenu -p "Send to $label")
          fi
          store=''${XDG_DATA_HOME:-$HOME/.local/share}/vicinae
          # offer id <TAB> one-line preview, newest first (vicinae's order).
          rows=$(sqlite3 -readonly -separator $'\t' "$store/clipboard.db" "
            SELECT o.id, trim(replace(replace(replace(substr(o.text_preview, 1, 160),
                     char(10), ' '), char(13), ' '), char(9), ' '))
            FROM selection s
            JOIN data_offer o ON o.selection_id = s.id AND o.mime_type = s.preferred_mime_type
            WHERE o.mime_type LIKE 'text/%' AND o.encryption_type = 0
              AND trim(coalesce(o.text_preview, ''')) != '''
            ORDER BY s.pinned_at DESC, s.updated_at DESC
            LIMIT 200") || { notify "Can't read the clipboard history" "$store/clipboard.db"; exit 1; }
          [ -n "$rows" ] || { notify "Clipboard history is empty"; exit 0; }
          # No --no-quick-look: with it vicinae 0.23 makes every row a file drag
          # source that swallows mouse clicks (only the keyboard works).
          choice=$(cut -f2- <<<"$rows" | "''${launcher[@]}") || exit 0
          [ -n "$choice" ] || exit 0
          offer=$(awk -F'\t' -v c="$choice" '$2 == c { print $1; exit }' <<<"$rows")
          if [ -z "$offer" ] || [ ! -f "$store/clipboard-data/$offer" ]; then
            notify "Couldn't find that clipboard entry"
            exit 1
          fi
          send_text "$(cat "$store/clipboard-data/$offer")"
          exit 0
        fi

        types=$(wl-paste --list-types 2>/dev/null) || { notify "The clipboard is empty"; exit 1; }
        if grep -qE '^(text/plain|UTF8_STRING|STRING|TEXT)' <<<"$types"; then
          send_text "$(wl-paste --no-newline --type text)"
        elif image=$(grep -m1 '^image/' <<<"$types"); then
          f=$(mktemp "$tmp/clipboard-XXXXXX.''${image#image/}")
          wl-paste --type "$image" >"$f"
          send_file "$f" "Image ($image)"
        else
          notify "Nothing to send" "The clipboard holds neither text nor an image."
          exit 1
        fi
      '';
    };

    # Bar widget (waybar shell): one phone glyph for the paired phones/tablets.
    # Accent while one is connected, faint while none is reachable, warning
    # with the percent under it when a connected one is at or below 20 % and
    # not charging; hidden with nothing paired. The tooltip says how each is
    # connected: LAN or Tailscale (all its addresses in 100.64.0.0/10).
    # Event-driven: re-renders on any kdeconnectd D-Bus signal (bursts
    # coalesced), 60 s heartbeat; outlives daemon restarts.
    d = self.design;
    px = n: "${toString n}px";
    status = pkgs.writeShellApplication {
      name = "kdeconnect-status";
      runtimeInputs = [pkgs.systemd pkgs.jq pkgs.glib.bin];
      text = ''
        set +e
        call() { busctl --user -j call org.kde.kdeconnect "$@" 2>/dev/null; }
        props() { call "$1" org.freedesktop.DBus.Properties GetAll s "$2" | jq -c '.data[0] | map_values(.data)'; }
        emit() {
          ids=$(call /modules/kdeconnect org.kde.kdeconnect.daemon devices bb false true | jq -r '.data[0][]?')
          devs=$(for id in $ids; do
            dev=$(props "/modules/kdeconnect/devices/$id" org.kde.kdeconnect.device)
            bat=$(props "/modules/kdeconnect/devices/$id/battery" org.kde.kdeconnect.device.battery)
            [ -n "$dev" ] && jq -cn --argjson d "$dev" --argjson b "''${bat:-null}" '$d + {battery: $b}'
          done | jq -sc 'map(select(.type == "phone" or .type == "tablet"))')
          jq -cn --unbuffered --argjson devs "''${devs:-[]}" '
            def tailnet: test("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.");
            def addrs: .reachableAddresses // [];
            def via: if (addrs | length) > 0 and (addrs | all(tailnet)) then "Tailscale" else "LAN" end;
            def low: .isReachable and .battery != null and (.battery.isCharging | not)
              and .battery.charge >= 0 and .battery.charge <= 20;
            def line: .name + "\n" + (
              if .isReachable
              then "Connected over \(via)" + (if (addrs | length) > 0 then " · " + (addrs | join(", ")) else "" end)
                + (if .battery != null and .battery.charge >= 0
                   then "\nBattery \(.battery.charge)%" + (if .battery.isCharging then " · charging" else "" end)
                   else "" end)
              else "Not reachable · right-click to reconnect" end);
            if $devs == [] then {text: ""}
            else ($devs | map(select(low)) | first) as $low
              | {text: ("󰄜" + (if $low then "\n<span size=\u0027${toString (d.type.size.caption * 768)}\u0027>\($low.battery.charge)</span>" else "" end)),
                 class: (if $low then "low" elif ($devs | any(.isReachable)) then "connected" else "away" end),
                 tooltip: ($devs | map(line) | join("\n\n"))}
            end'
        }
        while true; do
          emit
          while true; do
            read -r -t 60 _
            rc=$?
            if [ "$rc" -eq 0 ]; then
              n=0
              while [ "$n" -lt 200 ] && read -r -t 0.3 _; do n=$((n + 1)); done
            elif [ "$rc" -le 128 ]; then
              break
            fi
            emit
          done < <(gdbus monitor --session --dest org.kde.kdeconnect 2>/dev/null)
          sleep 5
        done
      '';
    };
  in {
    # KDEConnect uses UDP 1716 for discovery and TCP 1714-1764 for data.
    # Trusted networks only (home Wi-Fi, cable, tailscale0): never
    # announced to strangers on café Wi-Fi. From anywhere, pair the phone
    # "by IP" with the tailnet address (hosts registry).
    preferences.trustedNetworks = {
      allowedTCPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
      allowedUDPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
    };

    home-manager.users.${user} = {
      services.kdeconnect = {
        enable = true;
        indicator = true;
      };

      home.packages = [sendToPhone];

      # Launcher entries; the history picker needs vicinae's clipboard store.
      xdg.desktopEntries =
        {
          send-clipboard-to-phone = {
            name = "Send Clipboard to ${phoneName}";
            genericName = "KDE Connect";
            comment = "Copy the current clipboard (text or image) to the phone";
            exec = "${lib.getExe sendToPhone}";
            icon = "kdeconnect";
            categories = ["Utility"];
            terminal = false;
          };
        }
        // lib.optionalAttrs hasVicinae {
          send-history-to-phone = {
            name = "Send from Clipboard History to ${phoneName}";
            genericName = "KDE Connect";
            comment = "Pick an earlier clipboard entry and copy it to the phone";
            exec = "${lib.getExe sendToPhone} --pick";
            icon = "kdeconnect";
            categories = ["Utility"];
            terminal = false;
          };
        };

      # KDE Connect needs WAYLAND_DISPLAY which is only available after sway
      # imports the environment. Wait for sway-session.target.
      systemd.user.services.kdeconnect = {
        Unit = {
          After = ["sway-session.target"];
          PartOf = ["graphical-session.target"];
          Requisite = ["sway-session.target"];
        };
      };
      systemd.user.services.kdeconnect-indicator = {
        Unit = {
          After = ["sway-session.target"];
          PartOf = ["graphical-session.target"];
          Requisite = ["sway-session.target"];
        };
      };

      systemd.user.services.kdeconnect-reconnect = {
        Unit = {
          Description = "Re-announce KDE Connect while a paired device is unreachable";
          After = ["kdeconnect.service"];
          Requisite = ["sway-session.target"];
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe reconnect;
        };
      };
      systemd.user.timers.kdeconnect-reconnect = {
        Unit.PartOf = ["sway-session.target"];
        Timer = {
          OnActiveSec = "1min";
          OnUnitActiveSec = "1min";
        };
        Install.WantedBy = ["sway-session.target"];
      };

      # Placed next to bluetooth by waybar.nix. Left: KDE Connect window.
      # Right: reconnect now.
      programs.waybar = lib.mkIf (config.preferences.desktopShell == "waybar") {
        settings.mainBar."custom/kdeconnect" = {
          exec = lib.getExe status;
          return-type = "json";
          justify = "center";
          hide-empty-text = true;
          on-click = "${kdeconnect}/bin/kdeconnect-app";
          on-click-right = "${kdeconnect}/bin/kdeconnect-cli --refresh";
        };
        style = lib.mkAfter ''
          #custom-kdeconnect {
            padding: ${px d.bar.itemPaddingY} 0;
            margin: ${px d.bar.itemMarginY} ${px d.bar.itemMarginX};
            border-radius: ${px d.bar.radius};
            color: @fg-faint;
          }
          #custom-kdeconnect:hover { background: @tint; }
          #custom-kdeconnect:active { background: @tint-pressed; }
          #custom-kdeconnect.connected { color: @accent; }
          #custom-kdeconnect.low { color: @warning; }
        '';
      };
    };
  };
}
