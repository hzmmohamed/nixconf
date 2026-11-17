{self, ...}: {
  # Direct ethernet cable between two own machines (butternut <-> hazel) as a
  # plain point-to-point link (review §7.12, option B):
  #
  #   cable              static <registry cable>/24, NO gateway, NO DHCP/DNS/NAT,
  #                      never-default (v4 + v6). Autoconnects on carrier. Local
  #                      traffic only; internet stays on Wi-Fi on both ends.
  #   <me>-shares        manual fallback: THIS host shares its internet (NM shared
  #                      mode: dnsmasq DHCP/DNS + NAT) on `cableShare`
  #   <peer>-shares      manual fallback: take internet FROM the peer (DHCP,
  #                      route metric 700, so any Wi-Fi uplink still wins)
  #
  # Profile names are symmetric, so a mode is one profile name on both ends:
  # `cable-mode link | butternut-shares | hazel-shares | status` drives the
  # peer over SSH (delayed, so the link drop doesn't cut the command) and then
  # this host. The share subnets differ per host (registry `cableShare`), so a
  # half-flipped pair never has two hosts claiming one address, and neither
  # shared profile ever autoconnects (two DHCP servers would break both).
  #
  # Addresses come from the hosts registry (modules/hosts-registry.nix):
  # butternut 10.42.0.1, hazel 10.42.0.2. butternut's initrd SSH
  # (headless-boot.nix) uses the same 10.42.0.1/24 on eno2.
  #
  # Firewall: the cable is trusted (trusted-networks): via `interface` when the
  # NIC name is known, via the connection ids otherwise. 53/67 are opened for
  # the shared-mode dnsmasq.
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

    shareMine = "${me}-shares";
    sharePeer = "${cfg.peer}-shares";
    profileNames = ["cable" shareMine sharePeer];

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
      runtimeInputs = [config.networking.networkmanager.package pkgs.openssh pkgs.iproute2 pkgs.iputils pkgs.coreutils];
      text = ''
        usage() {
          echo "usage: cable-mode link|${shareMine}|${sharePeer}|status" >&2
          echo "  link             static ${cfg.address} <-> ${cfg.peer}, internet stays on Wi-Fi (default)" >&2
          echo "  ${shareMine}  this host shares its internet to ${cfg.peer} over the cable" >&2
          echo "  ${sharePeer}  ${cfg.peer} shares its internet to this host" >&2
          exit 2
        }
        mode=''${1:-status}
        case "$mode" in
          status)
            nmcli -f NAME,DEVICE,STATE connection show --active | grep -E '^(NAME|cable|[a-z]+-shares) ' || echo "no cable profile active"
            ip -4 -br addr | grep ' 10\.42\.' || true
            exit 0
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
        nmcli connection up "$profile"

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
  in {
    options.preferences.cable = {
      interface = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "eno2";
        description = ''
          Wired NIC the cable plugs into. `null`: the profiles match any wired
          NIC, and NM stops auto-creating "Wired connection 1" (else it would
          compete with `cable`).
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
    };

    config = {
      assertions = [
        {
          assertion = (regMe.cable or null) != null && cfg.peer != "";
          message = "cable-link: ${me} needs `cable`/`cableShare` in modules/hosts-registry.nix and a peer with a cable address.";
        }
      ];

      networking.networkmanager.ensureProfiles.profiles = {
        cable = lib.recursiveUpdate (base "cable") {
          connection = {
            autoconnect = true;
            # Above NM's auto "Wired connection 1" (0) and any imperative profile.
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
          connection.autoconnect = false;
          ipv4 = {
            method = "auto";
            route-metric = 700; # Wi-Fi (600) keeps the default route when present
          };
        };
      };

      networking.networkmanager.settings.main = lib.mkIf (cfg.interface == null) {
        no-auto-default = "*";
      };

      preferences.trustedNetworks =
        {
          connections = profileNames;
          interfaces = lib.optional (cfg.interface != null) cfg.interface;
        }
        # NIC name unknown: shared-mode dnsmasq ports go into the trusted set
        # (nothing else listens on 53/67, the resolved stub is loopback-only).
        // lib.optionalAttrs (cfg.interface == null) {
          allowedUDPPorts = [53 67];
          allowedTCPPorts = [53];
        };

      # NM's dnsmasq serves DHCP (67) + DNS (53) in shared mode; NM's own nft
      # rules don't bypass the NixOS firewall's input chain.
      networking.firewall.interfaces = lib.mkIf (cfg.interface != null) {
        ${cfg.interface} = {
          allowedUDPPorts = [53 67];
          allowedTCPPorts = [53];
        };
      };

      environment.systemPackages = [cableMode];
    };
  };
}
