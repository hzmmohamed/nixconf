{self, ...}: {
  # Client side of a host's binary cache. Default: ONE URL over the tailnet
  # (`http://<host>:5000`; /etc/hosts from the hosts registry, the server
  # admits 5000 on tailscale0). Tailscale picks the fastest direct path by
  # itself (the cable, the home LAN, else the internet), so there is no
  # per-network URL that times out when its network is absent (the old
  # cable URL cost 5 x 3 s per Nix run without the cable). The cable/LAN
  # URLs remain as opt-in options. Tried before cache.nixos.org.
  #
  # Not `<host>.local`: mDNS can hand back the host's Wi-Fi address, where
  # the cache port is closed (butternut serves it on eno2 + tailscale0).
  flake.nixosModules.lan-cache = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.lan-cache;
  in {
    options.preferences.lan-cache = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "butternut";
        description = "Host serving the cache; its public key is looked up in `self.nixServeKeys`.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://10.42.0.1:5000";
        description = ''
          Optional cache URL over the cable (cable-link address). Off by
          default: the tailnet URL already rides the cable when it is up.
        '';
      };

      lanUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = let
          lan = self.hosts.${cfg.host}.lan or null;
        in
          if lan == null
          then null
          else "http://${lan}:5000";
        defaultText = lib.literalMD "`http://<registry lan address of host>:5000`, `null` while the host has no `lan` reservation";
        description = "Cache URL over the home LAN (the host's wired DHCP reservation).";
      };

      lanPriority = lib.mkOption {
        type = lib.types.int;
        default = 15;
        description = "Priority of the LAN URL (after the cable, before the tailnet).";
      };

      tailnetUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "http://${cfg.host}:5000";
        defaultText = lib.literalMD "`http://<host>:5000`";
        description = ''
          Second URL over the tailnet (any network). `null` disables it. Costs
          at most `connect-timeout` seconds per Nix run when the host is away.
        '';
      };

      tailnetPriority = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Priority of the tailnet URL (lower wins; cache.nixos.org is 40).";
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Substituter priority (lower wins; cache.nixos.org is 40).";
      };
    };

    config.nix.settings = {
      extra-substituters =
        lib.optional (cfg.url != null) "${cfg.url}?priority=${toString cfg.priority}"
        ++ lib.optional (cfg.lanUrl != null) "${cfg.lanUrl}?priority=${toString cfg.lanPriority}"
        ++ lib.optional (cfg.tailnetUrl != null) "${cfg.tailnetUrl}?priority=${toString cfg.tailnetPriority}";
      extra-trusted-public-keys = [self.nixServeKeys.${cfg.host}];
      # Make an absent cable cheap: give up quickly, then use other caches or build.
      connect-timeout = lib.mkDefault 3;
      fallback = lib.mkDefault true;
    };
  };
}
