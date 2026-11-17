{...}: {
  # mDNS (avahi) so hosts find each other as `<hostname>.local` on any shared
  # link — notably a direct ethernet cable, where there is no DNS server,
  # internet or Tailscale, and the phone hotspot.
  #
  # UDP 5353 is opened only on trusted networks (trusted-networks.nix: cable,
  # home, hotspot, tailscale0), so on café Wi-Fi avahi neither answers queries
  # nor resolves `.local`. systemd-resolved stays out of mDNS (dns.nix).
  flake.nixosModules.lan-discovery = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.lan-discovery;
  in {
    options.preferences.lan-discovery.interfaces = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = ["eno2" "wlo1"];
      description = ''
        Interfaces avahi publishes on and answers queries from. `null` means
        every interface. The firewall side is trusted-networks either way.
      '';
    };

    config = {
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        allowInterfaces = cfg.interfaces;
        openFirewall = false;
        publish = {
          enable = true;
          addresses = true;
        };
      };

      preferences.trustedNetworks.allowedUDPPorts = [5353];
    };
  };
}
