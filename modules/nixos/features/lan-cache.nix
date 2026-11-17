{self, ...}: {
  # Client side of a host's nix-serve cache reached over a direct ethernet
  # cable (see `ethernet-share` on the serving host). Tried before
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
        # The serving host's fixed address on the cable (NM shared mode). An IP
        # rather than `<host>.local`: mDNS could hand back the host's wifi
        # address, where the cache port is closed.
        default = "http://10.42.0.1:5000";
        description = "Cache URL as reachable over the cable.";
      };

      priority = lib.mkOption {
        type = lib.types.int;
        default = 10;
        description = "Substituter priority (lower wins; cache.nixos.org is 40).";
      };
    };

    config.nix.settings = {
      extra-substituters = ["${cfg.url}?priority=${toString cfg.priority}"];
      extra-trusted-public-keys = [self.nixServeKeys.${cfg.host}];
      # Make an absent cable cheap: give up quickly, then use other caches or build.
      connect-timeout = lib.mkDefault 3;
      fallback = lib.mkDefault true;
    };
  };
}
