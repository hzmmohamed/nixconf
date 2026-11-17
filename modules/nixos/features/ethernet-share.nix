{...}: {
  # Direct-cable "hub" side: a NetworkManager profile that puts an ethernet
  # port in shared mode. When a cable is plugged in, NM assigns this host
  # `address` (10.42.0.1 by default), runs dnsmasq for DHCP + DNS on the port
  # and NATs the peer to whatever uplink this host has (wifi). The peer needs
  # nothing but DHCP (NetworkManager's default for wired).
  #
  # Pair with `lan-discovery` on both ends so `<host>.local` resolves.
  flake.nixosModules.ethernet-share = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.ethernet-share;
  in {
    options.preferences.ethernet-share = {
      interface = lib.mkOption {
        type = lib.types.str;
        example = "eno2";
        description = "Ethernet interface to share (the one the cable plugs into).";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.1/24";
        description = ''
          This host's address on the cable, in CIDR form. The peer gets a DHCP
          lease from the same subnet. Keep NM's default unless it collides
          with another network.
        '';
      };
    };

    config = {
      networking.networkmanager.ensureProfiles.profiles.ethernet-share = {
        connection = {
          id = "ethernet-share";
          type = "ethernet";
          interface-name = cfg.interface;
          autoconnect = true;
          # Prefer this over NM's auto-generated "Wired connection 1".
          autoconnect-priority = 10;
        };
        ethernet = {};
        ipv4 = {
          method = "shared";
          address1 = cfg.address;
        };
        ipv6 = {
          method = "link-local";
          addr-gen-mode = "stable-privacy";
        };
      };

      # NM's dnsmasq serves DHCP (UDP 67) and DNS (53) on the shared port. NM's
      # own nft rules don't bypass the NixOS firewall's input chain, so open
      # them here — on this interface only.
      networking.firewall.interfaces.${cfg.interface} = {
        allowedUDPPorts = [53 67];
        allowedTCPPorts = [53];
      };
    };
  };
}
