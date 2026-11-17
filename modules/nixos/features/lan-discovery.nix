{...}: {
  # mDNS (avahi) so hosts find each other as `<hostname>.local` on any shared
  # link — notably a direct ethernet cable, where there is no DNS server,
  # internet or Tailscale.
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
      example = ["eno2"];
      description = ''
        Interfaces avahi publishes on and answers queries from (also where
        UDP 5353 is opened). `null` means every interface.
      '';
    };

    config = {
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        allowInterfaces = cfg.interfaces;
        # Restricted lists open 5353 per interface below instead.
        openFirewall = cfg.interfaces == null;
        publish = {
          enable = true;
          addresses = true;
        };
      };

      networking.firewall.interfaces = lib.mkIf (cfg.interfaces != null) (
        lib.genAttrs cfg.interfaces (_: {allowedUDPPorts = [5353];})
      );
    };
  };
}
