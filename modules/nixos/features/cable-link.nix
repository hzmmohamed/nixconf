{self, ...}: {
  # The laptops' ethernet port (butternut <-> hazel), picked automatically:
  # router → DHCP LAN, the other laptop → static cable link (review §7.12, §12.2).
  #
  #   lan                DHCP (v4 + v6), autoconnect-priority 60, dhcp-timeout
  #                      10 s, ipv4.may-fail=no, autoconnect-retries=1. Trusted
  #                      only behind the home router (trusted-networks checks
  #                      the gateway's MAC). Default route metric 100 (NM's
  #                      wired default) beats Wi-Fi's 600 on the same LAN.
  #   cable              static <registry cable>/24, NO gateway, NO DHCP/DNS/NAT,
  #                      never-default (v4 + v6), priority 50. Local traffic only;
  #                      internet stays on Wi-Fi on both ends. Trusted.
  #   <me>-shares        manual: THIS host shares its internet (NM shared mode:
  #                      dnsmasq DHCP/DNS + NAT) on `cableShare`
  #   <peer>-shares      manual: take internet FROM the peer (DHCP, route
  #                      metric 700, so any Wi-Fi uplink still wins); optionally
  #                      marked metered (peerSharesMetered)
  #
  # How the fallthrough works (NetworkManager 1.56, src/core/nm-policy.c):
  # with carrier, NM autoconnects the highest-priority profile, `lan`. If no
  # DHCP server answers within dhcp-timeout, IPv4 fails; may-fail=no makes
  # that fail the activation (with may-fail=yes an IPv6 link-local or RA
  # would "succeed" instead). The failure uses up `lan`'s single retry, which
  # blocks it on that device, and NM immediately autoconnects the next
  # candidate, `cable`. NM never pre-empts an active device for a
  # higher-priority profile, so the 300 s retry reset changes nothing while
  # the cable is up. Unplug/replug (DISCONNECTED with reason CARRIER, coming
  # from UNAVAILABLE) resets the retries: the next plug tries `lan` first
  # again. Two laptops that both try DHCP first: neither runs a DHCP server
  # (the shares profiles never autoconnect), both time out, both land on
  # `cable` (10.42.0.1 <-> .2) about 10 s after link-up.
  #
  # `lan` rejects DHCP offers from the peers' shared-mode dnsmasq
  # (10.42.0.0/16): when one end is in `<me>-shares` mode, the other falls
  # back to `cable` (same /24 as butternut-shares) instead of silently
  # taking the shared uplink under the untrusted `lan` name; `cable-mode`
  # switches both ends explicitly.
  #
  # Router slower than the laptop (after a power cut): `lan` times out and
  # the port ends up on `cable`. `wired-recheck` (timer, every 5 min) retries
  # `lan` once whenever `cable` is up but the peer does not answer on its
  # cable address. With the peer there, it does nothing.
  #
  # `cable-mode link | lan | auto | butternut-shares | hazel-shares | status`:
  # link and the shares modes flip both ends (the peer over SSH, delayed so
  # the link drop doesn't cut the command); `lan` and `auto` (DHCP, else
  # cable: "reconnect wired") are local only. The share subnets differ per
  # host (registry `cableShare`), so a half-flipped pair never has two hosts
  # claiming one address, and neither shared profile ever autoconnects (two
  # DHCP servers would break both).
  #
  # Addresses come from the hosts registry (modules/hosts-registry.nix):
  # butternut 10.42.0.1, hazel 10.42.0.2. butternut's initrd SSH
  # (headless-boot.nix) uses the same 10.42.0.1/24 on eno2.
  #
  # Firewall: trust is per connection (trusted-networks), never per port:
  # the same NIC is the home LAN one day and a café LAN the next. 53/67 are
  # in the trusted set for the shared-mode dnsmasq (nothing else listens
  # there; the resolved stub is loopback-only).
  flake.nixosModules.cable-link = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.cable;
    me = config.networking.hostName;
    reg = self.hosts;
    regMe = reg.${me} or {};
    cablePeers = lib.attrNames (lib.filterAttrs (n: h: n != me && (h.cable or null) != null) reg);
    peerCable = (reg.${cfg.peer} or {}).cable or "";
    nm = config.networking.networkmanager.package;

    shareMine = "${me}-shares";
    sharePeer = "${cfg.peer}-shares";

    # nmcli `ifname` argument when the NIC is known.
    ifnameArg = lib.optionalString (cfg.interface != null) " ifname ${cfg.interface}";

    base = id: {
      connection =
        {
          inherit id;
          type = "ethernet";
        }
        // lib.optionalAttrs (cfg.interface != null) {interface-name = cfg.interface;};
      ethernet = {};
      # Never a v6 default route over the cable.
      ipv6 = {
        method = "link-local";
        addr-gen-mode = "stable-privacy";
        never-default = true;
      };
    };

    cableMode = pkgs.writeShellApplication {
      name = "cable-mode";
      runtimeInputs = [nm pkgs.openssh pkgs.iproute2 pkgs.iputils pkgs.coreutils pkgs.gnugrep];
      text = ''
        usage() {
          echo "usage: cable-mode link|lan|auto|${shareMine}|${sharePeer}|status" >&2
          echo "  link             static ${cfg.address} <-> ${cfg.peer}, internet stays on Wi-Fi (both ends)" >&2
          echo "  lan              DHCP on a router/LAN (this host only)" >&2
          echo "  auto             reconnect wired: DHCP first, else the cable link (this host only)" >&2
          echo "  ${shareMine}  this host shares its internet to ${cfg.peer} over the cable" >&2
          echo "  ${sharePeer}  ${cfg.peer} shares its internet to this host" >&2
          exit 2
        }
        mode=''${1:-status}
        case "$mode" in
          status)
            nmcli -f NAME,DEVICE,STATE connection show --active \
              | grep -E '^(NAME|lan|cable|[a-z]+-shares) ' || echo "no wired profile active"
            ip -4 -br addr show${lib.optionalString (cfg.interface != null) " dev ${cfg.interface}"} | grep -v '^lo ' || true
            for f in /run/trusted-networks/*; do
              [ -e "$f" ] && echo "trusted: ''${f##*/} ($(cat "$f"))"
            done
            exit 0
            ;;
          lan)
            exec nmcli connection up lan${ifnameArg}
            ;;
          auto)
            echo ">> trying DHCP (lan, up to 10 s)"
            if nmcli connection up lan${ifnameArg}; then exit 0; fi
            echo ">> no DHCP server: cable link"
            exec nmcli connection up cable${ifnameArg}
            ;;
          link) profile=cable ;;
          ${shareMine} | ${sharePeer}) profile=$mode ;;
          *) usage ;;
        esac

        # Any working path to the peer (ssh config from hosts-registry sets
        # port/user/host key). The remote half runs detached after 2 s, so it
        # survives this link going down.
        target=""
        for c in ${cfg.peer}-cable ${cfg.peer}.local ${cfg.peer}; do
          if ssh -o ConnectTimeout=3 -o BatchMode=yes "$c" true 2>/dev/null; then
            target=$c
            break
          fi
        done
        if [ -n "$target" ]; then
          echo ">> ${cfg.peer} (via $target): nmcli connection up $profile (in 2 s)"
          # shellcheck disable=SC2029  # $profile is one of three fixed names
          ssh "$target" "setsid -f sh -c 'sleep 2; nmcli connection up $profile' </dev/null >/dev/null 2>&1"
        else
          echo "!! ${cfg.peer} unreachable: run 'nmcli connection up $profile' there yourself" >&2
        fi

        echo ">> local: nmcli connection up $profile"
        nmcli connection up "$profile"${ifnameArg}

        echo ">> waiting for ${cfg.peer}"
        for _ in $(seq 1 15); do
          for c in ${cfg.peer}-cable ${cfg.peer}.local; do
            if ping -c1 -W1 "$c" >/dev/null 2>&1; then
              echo ">> ${cfg.peer} answers as $c"
              exit 0
            fi
          done
          sleep 2
        done
        echo "!! no answer from ${cfg.peer} yet (shared modes give it a DHCP address: try ${cfg.peer}.local)" >&2
        exit 1
      '';
    };

    # Runs as root from a timer: a `cable` profile nobody answers on is most
    # likely a router port whose DHCP server was not ready at link-up.
    wiredRecheck = pkgs.writeShellApplication {
      name = "wired-recheck";
      runtimeInputs = [nm pkgs.iputils pkgs.gawk pkgs.util-linux];
      text = ''
        dev=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: '$1 == "cable" { print $2; exit }')
        [ -n "$dev" ] || exit 0
        if ping -c2 -W1 -I "$dev" ${peerCable} >/dev/null 2>&1; then
          exit 0 # a real cable link: the peer answers
        fi
        logger -t wired-recheck "cable on $dev but ${cfg.peer} (${peerCable}) is silent: retrying DHCP (lan)"
        # On failure NM falls back to `cable` on its own (lan's retry is used up).
        nmcli connection up lan ifname "$dev" >/dev/null 2>&1 || true
      '';
    };
  in {
    options.preferences.cable = {
      interface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "eno2";
        description = ''
          Wired NIC the cable / LAN plugs into. `null`: the profiles match any
          wired NIC (USB adapters too) and NM creates no "Wired connection 1"
          for any of them.
        '';
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "${regMe.cable}/24";
        defaultText = lib.literalExpression ''"''${self.hosts.<host>.cable}/24"'';
        description = "This host's static address on the cable (CIDR).";
      };

      shareAddress = lib.mkOption {
        type = lib.types.str;
        default = regMe.cableShare;
        defaultText = lib.literalExpression "self.hosts.<host>.cableShare";
        description = "Address (CIDR) used when this host shares its internet (`<host>-shares`).";
      };

      peer = lib.mkOption {
        type = lib.types.str;
        default = lib.head (cablePeers ++ [""]);
        description = "The machine at the other end of the cable (a hosts-registry name).";
      };

      dhcpTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = ''
          Seconds `lan` waits for a DHCP lease before giving up and letting
          `cable` take the port (so also the delay before a laptop-to-laptop
          link comes up).
        '';
      };

      peerSharesMetered = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Mark `<peer>-shares` as metered (the peer is a carried device that
          may be on a phone hotspot).
        '';
      };
    };

    config = {
      assertions = [
        {
          assertion = (regMe.cable or null) != null && cfg.peer != "";
          message = "cable-link: ${me} needs `cable`/`cableShare` in modules/hosts-registry.nix and a peer with a cable address.";
        }
      ];

      networking.networkmanager.ensureProfiles.profiles = {
        lan = lib.recursiveUpdate (base "lan") {
          connection = {
            autoconnect = true;
            autoconnect-priority = 60; # above `cable` (50)
            # One failed DHCP attempt blocks `lan` on this device until the
            # cable is replugged (or 300 s pass): NM moves on to `cable`.
            autoconnect-retries = 1;
          };
          ipv4 = {
            method = "auto";
            dhcp-timeout = cfg.dhcpTimeout;
            may-fail = false; # no IPv4 lease = failed activation → fall through
            # The peers' shared-mode dnsmasq (cableShare subnets).
            dhcp-reject-servers = "10.42.0.0/16;";
          };
          ipv6 = {
            method = "auto";
            never-default = false;
            may-fail = true;
          };
        };

        cable = lib.recursiveUpdate (base "cable") {
          connection = {
            autoconnect = true;
            # Below `lan`, above any imperative profile (default 0).
            autoconnect-priority = 50;
          };
          ipv4 = {
            method = "manual";
            address1 = cfg.address; # no gateway → no default route
            never-default = true;
            ignore-auto-dns = true;
          };
        };

        ${shareMine} = lib.recursiveUpdate (base shareMine) {
          connection.autoconnect = false;
          ipv4 = {
            method = "shared";
            address1 = cfg.shareAddress;
          };
        };

        ${sharePeer} = lib.recursiveUpdate (base sharePeer) {
          connection =
            {
              autoconnect = false;
            }
            // lib.optionalAttrs cfg.peerSharesMetered {
              metered = "yes";
            };
          ipv4 = {
            method = "auto";
            route-metric = 700; # Wi-Fi (600) keeps the default route when present
          };
        };
      };

      # ensure-profiles runs after NetworkManager starts: without this NM
      # would create "Wired connection 1" first and autoconnect it.
      networking.networkmanager.settings.main.no-auto-default =
        if cfg.interface == null
        then "*"
        else "interface-name:${cfg.interface}";

      preferences.trustedNetworks = {
        connections = ["cable" shareMine sharePeer];
        # Trusted only behind a known gateway (the home router).
        gatewayConnections = ["lan"];
        # Shared-mode dnsmasq: DHCP + DNS for the peer.
        allowedUDPPorts = [53 67];
        allowedTCPPorts = [53];
      };

      systemd.services.wired-recheck = {
        description = "Retry DHCP on a cable link nobody answers on";
        after = ["NetworkManager.service"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe wiredRecheck;
        };
      };
      systemd.timers.wired-recheck = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "5min";
        };
      };

      # ethtool: link/EEE diagnostics on the wired port.
      environment.systemPackages = [cableMode pkgs.ethtool];
    };
  };
}
