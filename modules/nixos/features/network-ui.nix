# Network UI for the desktop (feature: network-ui, imported by `desktop`).
#
#   net-status   one snapshot of Wired / Wi-Fi / Tailscale as three waybar
#                JSON objects sharing one tooltip (devices, IPs, trust):
#                  net-status json | update | show <wired|wifi|tailscale> | watch
#                `watch` (user service, waybar shell only) refreshes the cache
#                in $XDG_RUNTIME_DIR/net-status and sends waybar SIGRTMIN+12
#                on every `nmcli monitor` line, address/route change (Wi-Fi,
#                Tailscale up/down, exit node = table 52 routes) and change in
#                /run/trusted-networks, debounced; plus one refresh every
#                2 min for the Wi-Fi signal strength (NM sends no event).
#   net-menu     dmenu-style picker ("Network" in the launcher, click on the
#                bar's network glyphs): Wi-Fi connect (saved + scanned) and
#                radio toggle, reconnect wired, cable modes, captive portal,
#                Tailscale up/down + exit nodes, copy an IP, status, nmtui.
#     NET_MENU_LAUNCHER  dmenu command (default: vicinae dmenu -p Network)
#
# Wired kinds: `lan` (DHCP behind a router), `cable` / `<host>-shares` (the
# direct link to the cable-link peer), connecting, no carrier. Profile names
# and the peer come from cable-link when the host imports it.
{self, ...}: {
  flake.nixosModules.network-ui = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    me = config.networking.hostName;
    nm = config.networking.networkmanager.package;
    ts = config.services.tailscale;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    terminal = lib.getExe selfpkgs.terminal;

    # cable-link is optional: profile names and peer when present.
    cable = lib.attrByPath ["preferences" "cable"] null config;
    hasCable = cable != null;
    peer =
      if hasCable
      then cable.peer
      else "";
    wiredIf =
      if hasCable && cable.interface != null
      then cable.interface
      else "";
    tsEnabled =
      if ts.enable
      then "yes"
      else "no";
    # cable-mode auto: DHCP first, else the static cable link.
    wiredReconnect =
      if hasCable
      then ''run "Wired: reconnect" cable-mode auto''
      else ''run "Wired: reconnect" nmcli device connect "$wired_if"'';

    # Everything a module shows is decided here, from plain strings collected
    # by the shell. Glyphs: Material Design (Nerd Font), like the rest of the bar.
    statusJq = pkgs.writeText "net-status.jq" ''
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      def small($s): "\n<span size='small'>\($s)</span>";
      def trustword($t): if $t == "" then "untrusted" else "trusted" end;
      def ipx($a): if $a == "" then "no address" else $a end;

      ($ts | try fromjson catch null) as $t
      | (($t | type) == "object") as $tsok
      | ( if $wdev == "" then "none"
          elif ($wstate | startswith("unavailable")) then "nocarrier"
          elif ($wstate | startswith("connecting")) then "connecting"
          elif ($wstate | startswith("connected")) then
            ( if $wconn == "cable" then "cable"
              elif $wconn == ($me + "-shares") then "share-out"
              elif $peer != "" and $wconn == ($peer + "-shares") then "share-in"
              else "lan" end )
          else "idle" end ) as $wk
      | ($fstate | startswith("connected")) as $wifiup
      | (($fsignal | tonumber?) // 0) as $sig
      | (if $tsok then ($t.BackendState // "") else "" end) as $tstate
      | ( if $tsok and ($t.ExitNodeStatus != null) then
            $t.ExitNodeStatus.ID as $id
            | ( [ ($t.Peer // {})[] | select(.ID == $id)
                  | ((.DNSName // "") | split(".")[0]) as $n
                  | if $n != "" then $n else .HostName end ][0] ) // "?"
          else "" end ) as $exit
      | ( ( if $wdev == "" then [] else
              [ "<b>Wired</b>  \($wdev) · " + (
                  if $wk == "lan" then "LAN (\($wconn)) · \(ipx($wip)) · \(trustword($wtrust))"
                  elif $wk == "cable" then "cable link to \($peer) · \(ipx($wip))"
                  elif $wk == "share-out" then "sharing internet to \($peer) · \(ipx($wip))"
                  elif $wk == "share-in" then "internet from \($peer) · \(ipx($wip))"
                  elif $wk == "connecting" then "connecting \($wconn)…"
                  elif $wk == "nocarrier" then "no carrier (unplugged)"
                  else "link up, no connection" end | esc ) ]
            end )
          + ( if $fdev == "" then [] else
                [ "<b>Wi-Fi</b>  " + (
                    if $wifiup then "\($fssid) (\($fconn)) · \($sig)% · \(ipx($fip)) · \(trustword($ftrust))"
                    elif $radio == "disabled" then "off"
                    elif ($fstate | startswith("connecting")) then "connecting \($fconn)…"
                    else "not connected" end | esc ) ]
              end )
          + ( if $tsen != "yes" then [] else
                [ "<b>Tailscale</b>  " + (
                    if $tstate == "Running" then
                      "up · \($t.Self.TailscaleIPs[0] // "?")"
                      + (if $exit != "" then " · exit node \($exit)" else "" end)
                    elif $tstate == "Stopped" then "down"
                    elif $tstate == "" then "tailscaled not running"
                    else $tstate end | esc ) ]
              end )
          + [ "Internet: \($conn)", "", "Click: network menu · Right: nmtui" ]
          | join("\n") ) as $tip
      | { wired:
            ( if $wk == "none" then {text: "", class: ["none"]}
              elif $wk == "lan" then {text: "󰈀", class: ["lan", trustword($wtrust)]}
              elif $wk == "cable" then {text: "󰌘", class: ["cable"]}
              elif $wk == "share-out" then {text: ("󰌘" + small("out")), class: ["cable", "share"]}
              elif $wk == "share-in" then {text: ("󰌘" + small("in")), class: ["cable", "share"]}
              elif $wk == "connecting" then {text: "󰌚", class: ["connecting"]}
              elif $wk == "nocarrier" then {text: "󰈂", class: ["nocarrier"]}
              else {text: "󰌙", class: ["idle"]} end ),
          wifi:
            ( if $wifiup then
                { text: (if $sig < 25 then "󰤟" elif $sig < 50 then "󰤢" elif $sig < 75 then "󰤥" else "󰤨" end),
                  class: (["wifi", trustword($ftrust)]
                          + (if $conn == "portal" or $conn == "limited" then ["limited"] else [] end)) }
              elif $uplink != "yes" then {text: "󰤮", class: ["offline"]}
              else {text: "", class: ["none"]} end ),
          tailscale:
            ( if $tsen != "yes" then {text: "", class: ["none"]}
              elif $tstate == "Running" then
                ( if $exit != "" then {text: ("󰖂" + small("exit")), class: ["up", "exit"]}
                  else {text: "󰖂", class: ["up"]} end )
              elif $tstate == "Stopped" then {text: "󰖂", class: ["stopped"]}
              else {text: "󰖂", class: ["error"]} end ) }
      | map_values(. + {tooltip: $tip, alt: .class[0]})
    '';

    netStatus = pkgs.writeShellApplication {
      name = "net-status";
      runtimeInputs =
        [nm pkgs.jq pkgs.iproute2 pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.inotify-tools pkgs.systemd]
        ++ lib.optional ts.enable ts.package;
      text = ''
        wired_if=${lib.escapeShellArg wiredIf}
        tdir=/run/trusted-networks
        cache="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/net-status"

        trust() { if [ -n "$1" ] && [ -e "$tdir/$1" ]; then cat "$tdir/$1"; fi; }
        ip4() { nmcli -g IP4.ADDRESS device show "$1" 2>/dev/null | sed 's/ | /, /g'; }

        snapshot() {
          local line d t s c rest
          wdev="" wstate="" wconn="" fdev="" fstate="" fconn=""
          while IFS= read -r line; do
            line=''${line//\\:/$'\037'}
            IFS=: read -r d t s c <<<"$line"
            c=''${c//$'\037'/:}
            case "$t" in
              ethernet)
                if [ -n "$wired_if" ]; then
                  [ "$d" = "$wired_if" ] || continue
                elif [ -n "$wdev" ] || [ "$s" = unmanaged ]; then
                  continue
                fi
                wdev=$d wstate=$s wconn=$c
                ;;
              wifi)
                [ -z "$fdev" ] || continue
                fdev=$d fstate=$s fconn=$c
                ;;
            esac
          done < <(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null)

          wip="" wtrust="" fip="" ftrust="" fssid="" fsignal=""
          if [ -n "$wdev" ]; then
            wip=$(ip4 "$wdev")
            wtrust=$(trust "$wdev")
          fi
          if [ -n "$fdev" ] && [[ $fstate == connected* ]]; then
            fip=$(ip4 "$fdev")
            ftrust=$(trust "$fdev")
            line=$(nmcli -t -f ACTIVE,SIGNAL,SSID device wifi list ifname "$fdev" --rescan no 2>/dev/null | grep -m1 '^yes:' || true)
            rest=''${line#yes:}
            fsignal=''${rest%%:*}
            fssid=''${rest#*:}
            fssid=''${fssid//\\:/:}
          fi
          radio=$(nmcli radio wifi 2>/dev/null || echo unknown)
          conn=$(nmcli -t networking connectivity 2>/dev/null || echo unknown)
          if ip -4 route show default | grep -qv 'dev tailscale0'; then uplink=yes; else uplink=no; fi
          tsen=${tsEnabled}
          tsjson=""
          ${lib.optionalString ts.enable ''tsjson=$(tailscale status --json 2>/dev/null || true)''}

          jq -nc -f ${statusJq} \
            --arg me ${lib.escapeShellArg me} --arg peer ${lib.escapeShellArg peer} \
            --arg wdev "$wdev" --arg wstate "$wstate" --arg wconn "$wconn" --arg wip "$wip" --arg wtrust "$wtrust" \
            --arg fdev "$fdev" --arg fstate "$fstate" --arg fconn "$fconn" --arg fip "$fip" --arg ftrust "$ftrust" \
            --arg fssid "$fssid" --arg fsignal "$fsignal" --arg radio "$radio" \
            --arg conn "$conn" --arg uplink "$uplink" --arg tsen "$tsen" --arg ts "$tsjson"
        }

        update() {
          local json part
          mkdir -p "$cache"
          json=$(snapshot)
          for part in wired wifi tailscale; do
            jq -c ".$part" <<<"$json" >"$cache/$part.json.$$"
            mv -f "$cache/$part.json.$$" "$cache/$part.json"
          done
        }

        refresh() {
          update
          systemctl --user kill --kill-whom=main -s SIGRTMIN+12 waybar.service 2>/dev/null || true
        }

        events() {
          nmcli monitor 2>/dev/null &
          ip -o monitor address route 2>/dev/null &
          if [ -d "$tdir" ]; then
            inotifywait -m -q -e create,delete,close_write,moved_to "$tdir" 2>/dev/null &
          fi
          wait
        }

        watch() {
          local n rc
          refresh
          while :; do
            rc=0
            IFS= read -r -t 120 _ || rc=$?
            if [ "$rc" -ne 0 ] && [ "$rc" -le 128 ]; then
              exit 1 # every event source died: let systemd restart us
            fi
            # Debounce: let a burst settle (at most ~5 s), then one refresh.
            n=0
            while [ "$n" -lt 10 ] && IFS= read -r -t 0.5 _; do n=$((n + 1)); done
            refresh
          done < <(events)
        }

        case "''${1:-json}" in
          json) snapshot ;;
          update) update ;;
          show)
            part=''${2:?usage: net-status show wired|wifi|tailscale}
            [ -s "$cache/$part.json" ] || update
            cat "$cache/$part.json"
            ;;
          watch) watch ;;
          *)
            echo "usage: net-status json|update|show <wired|wifi|tailscale>|watch" >&2
            exit 2
            ;;
        esac
      '';
    };

    netMenu = pkgs.writeShellApplication {
      name = "net-menu";
      runtimeInputs =
        [nm pkgs.jq pkgs.iproute2 pkgs.coreutils pkgs.gawk pkgs.util-linux pkgs.libnotify pkgs.wl-clipboard netStatus]
        ++ lib.optional ts.enable ts.package;
      text = ''
        # No --no-quick-look: with it vicinae 0.23 makes every row a file drag
        # source that swallows mouse clicks (only the keyboard works).
        read -ra launcher <<<"''${NET_MENU_LAUNCHER:-vicinae dmenu -p Network}"
        notify() { notify-send -a Network -i network-workgroup "$@"; }

        # --run TITLE CMD...: runs detached from the picker, reports the result.
        if [ "''${1:-}" = --run ]; then
          title=$2
          shift 2
          if out=$("$@" 2>&1); then
            notify "$title" "$(tail -n 4 <<<"$out")"
          else
            notify -u critical "$title: failed" "$(tail -n 6 <<<"$out")"
          fi
          exit 0
        fi
        run() { setsid -f "$0" --run "$@" >/dev/null 2>&1; }
        term() { setsid -f ${terminal} "$@" >/dev/null 2>&1; }

        # "label<TAB>action<TAB>arg" lines; choose sets $action/$arg.
        entries=""
        add() { entries+="$1"$'\t'"$2"$'\t'"''${3:-}"$'\n'; }
        choose() {
          local choice line
          choice=$(printf '%s' "$entries" | cut -f1 | "''${launcher[@]}") || return 1
          [ -n "$choice" ] || return 1
          line=$(awk -F'\t' -v c="$choice" '$1 == c { print; exit }' <<<"$entries")
          [ -n "$line" ] || return 1
          action=$(cut -f2 <<<"$line")
          arg=$(cut -f3- <<<"$line")
        }

        wired_if=${lib.escapeShellArg wiredIf}
        if [ -z "$wired_if" ]; then
          wired_if=$(nmcli -t -f DEVICE,TYPE,STATE device | awk -F: '$2 == "ethernet" && $3 != "unmanaged" { print $1; exit }')
        fi

        wifi_menu() {
          local name type ssid l r inuse sig sec mark kind profile
          declare -A known=() seen=() secs=()
          while IFS=: read -r name type; do
            [ "$type" = 802-11-wireless ] || continue
            # Active profiles print extra (active-connection) lines: first line only.
            ssid=$(nmcli -g 802-11-wireless.ssid connection show "$name" 2>/dev/null | head -n1) || continue
            ssid=''${ssid//\\:/:}
            # First wins, active profiles first: `home`, not an imperative
            # duplicate of the same SSID.
            [ -n "''${known[$ssid]:-}" ] || known[$ssid]=$name
          done < <(nmcli -t -f NAME,TYPE connection show --active; nmcli -t -f NAME,TYPE connection show)

          entries=""
          add "Rescan networks" rescan
          while IFS= read -r l; do
            inuse=''${l%%:*}; r=''${l#*:}
            sig=''${r%%:*}; r=''${r#*:}
            sec=''${r%%:*}; ssid=''${r#*:}
            ssid=''${ssid//\\:/:}
            [ -n "$ssid" ] || continue
            [ -z "''${seen[$ssid]:-}" ] || continue
            seen[$ssid]=1
            secs[$ssid]=$sec
            mark=""
            [ "$inuse" = "*" ] && mark="● "
            profile=''${known[$ssid]:-}
            if [ -n "$profile" ]; then kind="saved: $profile"
            elif [ -z "$sec" ] || [ "$sec" = "--" ]; then kind="open"
            else kind="$sec"; fi
            add "$mark$ssid · $sig% · $kind" wifi-connect "$ssid"
          done < <(nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID device wifi list --rescan auto 2>/dev/null | sort -t: -k1,1r -k2,2nr)

          choose || exit 0
          case "$action" in
            rescan)
              nmcli device wifi rescan >/dev/null 2>&1 || true
              sleep 3
              wifi_menu
              ;;
            wifi-connect)
              ssid=$arg
              profile=''${known[$ssid]:-}
              if [ -n "$profile" ]; then
                run "Wi-Fi: $ssid" nmcli connection up id "$profile"
              elif [ -z "''${secs[$ssid]:-}" ] || [ "''${secs[$ssid]}" = "--" ]; then
                run "Wi-Fi: $ssid" nmcli device wifi connect "$ssid"
              else
                term nmtui-connect "$ssid" # asks for the password
              fi
              ;;
          esac
        }

        ip_menu() {
          local dev addr
          entries=""
          while read -r _ dev _ addr _; do
            [ "$dev" = lo ] && continue
            add "$dev  $addr" copy "''${addr%/*}"
          done < <(ip -o -4 addr show; ip -o -6 addr show scope global | grep -v temporary)
          choose || exit 0
          printf '%s' "$arg" | wl-copy
          notify "Copied" "$arg"
        }

        # Main menu.
        radio=$(nmcli radio wifi 2>/dev/null || echo missing)
        case "$radio" in
          enabled)
            add "Wi-Fi: connect to a network…" wifi
            add "Wi-Fi: turn off" wifi-off
            ;;
          disabled) add "Wi-Fi: turn on" wifi-on ;;
        esac
        if [ -n "$wired_if" ]; then
          add "Wired: reconnect $wired_if (LAN, else cable)" wired
        fi
        ${lib.optionalString hasCable ''
          add "Cable: link to ${peer} (static, both ends)" cable link
          add "Cable: ${me} shares its internet with ${peer}" cable ${me}-shares
          add "Cable: ${peer} shares its internet with ${me}" cable ${peer}-shares
          add "Cable: status" cable status
        ''}
        add "Captive portal: log in (plain DNS until done)" captive
        ${lib.optionalString ts.enable ''
          tsjson=$(tailscale status --json 2>/dev/null || echo '{}')
          if [ "$(jq -r '.BackendState // ""' <<<"$tsjson")" = Running ]; then
            add "Tailscale: disconnect (tailscale down)" ts down
          else
            add "Tailscale: connect (tailscale up)" ts up
          fi
          current=$(jq -r '.ExitNodeStatus.ID // empty' <<<"$tsjson")
          while IFS=$'\t' read -r id name addr; do
            [ -n "$name" ] || continue
            if [ "$id" = "$current" ]; then
              add "Tailscale: stop using exit node $name" exit ""
            else
              add "Tailscale: use exit node $name" exit "$addr"
            fi
          done < <(jq -r '(.Peer // {})[] | select(.ExitNodeOption)
                          | [.ID, (((.DNSName // "") | split(".")[0]) as $n | if $n != "" then $n else .HostName end),
                             .TailscaleIPs[0]] | @tsv' <<<"$tsjson")
        ''}
        add "Copy an IP address…" ips
        add "Show status" status
        add "Open nmtui" nmtui
        add "Connection editor" editor

        choose || exit 0
        case "$action" in
          wifi) wifi_menu ;;
          wifi-off) run "Wi-Fi off" nmcli radio wifi off ;;
          wifi-on) run "Wi-Fi on" nmcli radio wifi on ;;
          wired) ${wiredReconnect} ;;
          cable) run "Cable: $arg" cable-mode "$arg" ;;
          captive) term captive ;;
          ts) run "Tailscale $arg" tailscale "$arg" ;;
          exit) run "Exit node" tailscale set --exit-node="$arg" ;;
          ips) ip_menu ;;
          status)
            body=$(net-status json | jq -r '.wired.tooltip' | sed '/^Click:/d')
            notify "Network" "$body"
            ;;
          nmtui) term nmtui ;;
          editor) setsid -f ${pkgs.networkmanagerapplet}/bin/nm-connection-editor >/dev/null 2>&1 ;;
        esac
      '';
    };
  in {
    options.preferences.networkUi = {
      statusCommand = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        default = lib.getExe netStatus;
        description = "net-status (read by the bar).";
      };
      menuCommand = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        internal = true;
        default = lib.getExe netMenu;
        description = "net-menu (read by the bar).";
      };
    };

    config = lib.mkIf config.networking.networkmanager.enable {
      environment.systemPackages = [
        netStatus
        netMenu
        # "Network" in the launcher: same picker as a click on the bar.
        (pkgs.makeDesktopItem {
          name = "network-menu";
          desktopName = "Network";
          genericName = "Wi-Fi, wired, cable, Tailscale";
          comment = "Connect Wi-Fi, switch cable mode, captive portal, Tailscale, copy an IP";
          icon = "network-workgroup";
          exec = lib.getExe netMenu;
          categories = ["System" "Network"];
          keywords = ["wifi" "wlan" "ethernet" "wired" "lan" "cable" "tailscale" "vpn" "exit" "ip" "captive" "portal" "nmtui"];
        })
      ];

      home-manager.users.${user} = lib.mkIf (config.preferences.desktopShell == "waybar") {
        systemd.user.services.net-status-watch = {
          Unit = {
            Description = "Refresh the bar's network modules on NetworkManager / address / route events";
            PartOf = ["graphical-session.target"];
            After = ["graphical-session.target"];
          };
          Service = {
            ExecStart = "${lib.getExe netStatus} watch";
            Restart = "always";
            RestartSec = 5;
          };
          Install.WantedBy = ["graphical-session.target"];
        };
      };
    };
  };
}
