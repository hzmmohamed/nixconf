{config, ...}: let
  # User SSH keys (modules/ssh-keys.nix), referenced rather than copied.
  userKeys = config.flake.sshKeys;
in {
  # Single source of truth for the fleet's network identities. Consumed by
  # features/hosts-registry.nix (/etc/hosts, ssh client config, known_hosts),
  # features/syncthing.nix (device IDs + addresses), features/cable-link.nix
  # (cable addresses), features/tailscale.nix (tags) and lan-cache.
  #
  # Privacy (review open question 7): the tailnet domain and the 100.x
  # addresses are committed to this public repo. They are only routable from
  # inside the tailnet (CGNAT range, WireGuard-authenticated), and the names
  # already leak through CT logs once `tailscale cert` issues HTTPS certs. The
  # IPs ARE needed: they are the /etc/hosts fallback that keeps `ssh maple`
  # working while MagicDNS is off (`captive`, accept-dns=false) or broken.
  # Pin them in the admin console (Machines → … → Edit machine IPv4) so a
  # re-registration does not move them; otherwise /etc/hosts goes stale.
  #
  # Fields (all optional except where noted):
  #   tailnetName  MagicDNS label (default: the attribute name)
  #   ts4          tailnet IPv4 from `tailscale status` (read-only snapshot 2026-11-17)
  #   lan          home-LAN address (DHCP reservation on the WE router), null if none;
  #                gives /etc/hosts `<host>-lan` and a lan-cache URL
  #   cable        static address on the direct butternut <-> hazel cable (cable-link)
  #   cableShare   CIDR used by the `<host>-shares` fallback profile (NM shared mode)
  #   sshPort      sshd port; hosts without it get no ssh config (phone)
  #   hostKey      sshd ed25519 HOST key (/etc/ssh/ssh_host_ed25519_key.pub); enables
  #                programs.ssh.knownHosts + StrictHostKeyChecking for that host
  #   userKey      the user's ssh key living on that host (modules/ssh-keys.nix)
  #   syncthingId  Syncthing device ID
  #   roles        free-form, documentation + future generators
  #   tags         Tailscale ACL tags (docs/tailscale-policy.hujson). Only advertised
  #                when the host logs in with the OAuth client (tailscale.nix)
  #   buildOnTarget  `deploy` builds on the host itself instead of locally + nix copy
  #                (cloud boxes: only derivations cross the uplink)
  flake.tailnet.domain = "tail1a9f7c.ts.net";

  # The home LAN (WE router). A wired DHCP connection (cable-link `lan`) is
  # trusted only while its gateway is this IP *and* MAC (trusted-networks):
  # every WE customer has a 192.168.100.1. The MAC is not secret (any LAN
  # client sees it) but it is per device, so it is what identifies home.
  # TODO(user): on the home network (Wi-Fi or wired) run
  #   ip neigh show 192.168.100.1
  # and put the `lladdr` value here; until then `lan` stays untrusted.
  flake.networks.home = {
    gateway = "192.168.100.1";
    gatewayMac = null;
  };

  flake.hosts = {
    butternut = {
      ts4 = "100.105.41.75";
      lan = null; # TODO(user): reserve a DHCP address on the router, e.g. 192.168.100.3
      cable = "10.42.0.1";
      # butternut-shares keeps today's shared-mode address, so lan-cache and
      # butternut-cable also work in that mode.
      cableShare = "10.42.0.1/24";
      sshPort = 7654;
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPF8xUY7XvBEex4yjlcG51O8dhXiRFT+yp0LE393WD+J";
      userKey = userKeys.butternut or null;
      syncthingId = "MRJSBVI-MRVAT7V-WHLSZBC-5LX6KFD-VGCYP4E-W265N3K-B5URBIH-RPUTWQK";
      roles = ["desktop" "agent-host" "cache"];
      tags = [];
    };

    hazel = {
      ts4 = "100.126.38.74";
      lan = null;
      cable = "10.42.0.2";
      # A different subnet from the link, so a half-flipped cable never has
      # two hosts claiming the same address.
      cableShare = "10.42.1.1/24";
      sshPort = 7654;
      # TODO(user): `cat /etc/ssh/ssh_host_ed25519_key.pub` on hazel.
      hostKey = null;
      userKey = userKeys.hazel or null;
      # TODO(user): Syncthing GUI on hazel → Actions → Show ID.
      syncthingId = null;
      roles = ["desktop" "client"];
      tags = [];
    };

    maple = {
      ts4 = "100.111.5.48";
      lan = null;
      sshPort = 7654;
      hostKey = null; # TODO(user): host key once maple is back online
      userKey = userKeys.maple or null;
      syncthingId = "H7H47TV-XI7EQDB-U4RAQWU-BYMDKVT-6HNATQP-EDELRE7-35GLDGH-BKAUBAW";
      roles = ["server" "relay"];
      tags = ["tag:server"];
    };

    peacelily = {
      ts4 = "100.127.239.128";
      lan = null;
      sshPort = 7654;
      hostKey = null; # TODO(user): host key once peacelily is back online
      userKey = userKeys.peacelily or null;
      syncthingId = null;
      roles = ["server" "agent-host" "gpu"];
      tags = ["tag:server" "tag:gpu"];
    };

    # On-demand EC2 agent host (docs/plans/2026-11-17-aws-agent-host.md).
    # Tagged, not ephemeral: tailscaled state survives stop/start on EBS.
    fern = {
      ts4 = "100.78.82.41"; # fern-ts4: filled in by scripts/fern/enroll.sh after the first boot
      lan = null;
      sshPort = 7654;
      hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO5zQnKGTM1XbKt/puSLURDQeLZfvNhi747wMIO6fXYV"; # fern-hostKey: filled in by scripts/fern/enroll.sh
      userKey = null;
      syncthingId = null;
      roles = ["agent-host" "cloud"];
      tags = ["tag:cloud" "tag:agent-host"];
      # `deploy` builds on the box (eval here, substitutes inside AWS): only
      # derivations travel over a café connection, not the closure.
      buildOnTarget = true;
    };

    # Not a NixOS host: /etc/hosts name only (KDE Connect "add device by IP").
    phone = {
      tailnetName = "xiaomi-21081111rg";
      ts4 = "100.93.74.64";
      roles = ["phone"];
      tags = [];
    };
  };
}
