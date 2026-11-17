{self, ...}: {
  # Client side of a host's nix-serve cache, reached over the direct ethernet
  # cable (cable-link: static 10.42.0.1) and, as a second URL, over the
  # tailnet (`http://<host>:5000`; /etc/hosts from the hosts registry, the
  # server admits 5000 on tailscale0). Tried before
  # cache.nixos.org; when the cable is unplugged the connection fails within
  # `connect-timeout` seconds and Nix falls through to the other substituters.
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
        type = lib.types.str;
        # The serving host's static address on the cable (cable-link). An IP
        # rather than `<host>.local`: mDNS could hand back the host's wifi
        # address, where the cache port is closed.
        default = "http://${self.hosts.${cfg.host}.cable}:5000";
        defaultText = lib.literalMD "`http://<registry cable address of host>:5000` (10.42.0.1)";
        description = "Cache URL as reachable over the cable.";
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
        default = 20;
        description = "Priority of the tailnet URL (after the cable, before cache.nixos.org).";
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Substituter priority (lower wins; cache.nixos.org is 40).";
      };
    };

    config.nix.settings = {
      extra-substituters =
        ["${cfg.url}?priority=${toString cfg.priority}"]
        ++ lib.optional (cfg.tailnetUrl != null) "${cfg.tailnetUrl}?priority=${toString cfg.tailnetPriority}";
      extra-trusted-public-keys = [self.nixServeKeys.${cfg.host}];
      # Make an absent cable cheap: give up quickly, then use other caches or build.
      connect-timeout = lib.mkDefault 3;
      fallback = lib.mkDefault true;
    };
  };
}
