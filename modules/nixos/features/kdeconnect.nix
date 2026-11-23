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
