{...}: {
  # systemd-resolved on every host (imported by `general`). Review §2.1.
  #
  # Path with Tailscale up (accept-dns, "Override local DNS" on in the admin
  # console): tailscaled sees /etc/resolv.conf → resolved's stub and programs
  # resolved over D-Bus instead of overwriting resolv.conf: tailscale0 gets
  # DNS=100.100.100.100 with routing domain `~.` (+ the tailnet suffix), so
  # every name goes to MagicDNS → DoH upstreams. tailscaled down: resolved
  # just drops that link and uses the Wi-Fi/LAN DHCP servers (opportunistic
  # DoT, plain fallback, so captive portals still work). No restore races.
  #
  # nsswitch: mdns4_minimal [NOTFOUND=return] → resolve → files → dns.
  # `.local` stays with avahi/nss-mdns (resolved MulticastDNS=no, LLMNR=no);
  # resolved also answers from /etc/hosts (the hosts-registry entries).
  #
  # Escape hatch for captive portals: `captive` (below).
  flake.nixosModules.dns = {
    config,
    lib,
    pkgs,
    ...
  }: let
    nm = config.networking.networkmanager;
    ts = config.services.tailscale;

    captive = pkgs.writeShellApplication {
      name = "captive";
      runtimeInputs =
        [nm.package pkgs.coreutils pkgs.gawk pkgs.xdg-utils]
        ++ lib.optional ts.enable ts.package;
      text = ''
        # Café/hotel login pages hijack plain DNS. MagicDNS forwards to DoH and
        # resolved tries DoT first, so the hijack never happens and the portal
        # never shows. This turns both off until the portal is passed (or you
        # press Enter), then restores them. Needs no root: Tailscale operator
        # (tailscale.nix) + networkmanager group.
        url=''${1:-http://neverssl.com}
        devs=$(nmcli -t -f DEVICE,TYPE,STATE device \
          | awk -F: '$3 == "connected" && ($2 == "wifi" || $2 == "ethernet") {print $1}')

        restore() {
          echo "captive: restoring DNS settings"
          ${lib.optionalString ts.enable ''
          tailscale set --accept-dns=true || echo "captive: tailscale set failed (operator?)" >&2
        ''}
          for d in $devs; do nmcli device reapply "$d" >/dev/null 2>&1 || true; done
        }
        trap restore EXIT
        trap 'exit 130' INT TERM

        ${lib.optionalString ts.enable ''
          tailscale set --accept-dns=false || echo "captive: tailscale set failed (operator?)" >&2
        ''}
        for d in $devs; do
          nmcli device modify "$d" connection.dns-over-tls no >/dev/null 2>&1 \
            || echo "captive: could not turn off DoT on $d" >&2
        done

        echo "captive: plain DNS on: $devs. Opening $url"
        if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ]; then
          xdg-open "$url" >/dev/null 2>&1 &
        else
          echo "captive: no display; open $url in a browser" >&2
        fi
        echo "captive: waiting for full connectivity (Enter to stop now)"
        while :; do
          state=$(nmcli networking connectivity check 2>/dev/null || echo unknown)
          [ "$state" = full ] && { echo "captive: connectivity is full"; break; }
          if read -r -t 5; then break; fi
        done
      '';
    };
  in {
    services.resolved = {
      enable = true;
      settings.Resolve = {
        # Applies to non-Tailscale links only in practice: Tailscale owns `~.`
        # while up. Opportunistic = try DoT, fall back to plain (portals,
        # ISP/café resolvers without 853).
        DNSOverTLS = "opportunistic";
        # Egyptian ISP and café resolvers break DNSSEC (intermittent SERVFAIL
        # with allow-downgrade); the DoH upstreams behind MagicDNS validate.
        DNSSEC = false;
        LLMNR = false;
        # avahi owns UDP 5353 (lan-discovery, nss-mdns); spotifyd's libmdns too.
        MulticastDNS = false;
        # Only used when no link has any DNS server at all.
        FallbackDNS = ["1.1.1.1#cloudflare-dns.com" "9.9.9.9#dns.quad9.net"];
        # Deliberately no global DNS= / Domains=~.: a second global path would
        # race MagicDNS and leak names to it while Tailscale is up.
      };
    };

    networking.networkmanager = lib.mkIf nm.enable {
      # Chosen automatically when resolved is enabled; explicit for clarity.
      dns = "systemd-resolved";
      # Off by default on NixOS. Lets `captive` (and the applet) see "portal"
      # vs "full"; one small HTTP GET to gnome.org every 5 minutes.
      settings.connectivity = {
        enabled = true;
        uri = "http://nmcheck.gnome.org/check_network_status.txt";
        interval = 300;
      };
    };

    environment.systemPackages = lib.optional nm.enable captive;
  };
}
