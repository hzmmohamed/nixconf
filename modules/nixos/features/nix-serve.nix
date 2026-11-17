{...}: {
  # Public halves of the per-host nix-serve signing keys, keyed by hostname.
  # Safe to commit. Consumed by the `lan-cache` feature on client hosts.
  #
  # butternut's key comes from the old config (.repos/old-config, maple's
  # commented substituter); secrets/butternut/nix-serve.yaml is a byte-for-byte
  # copy of the old secret, so it should still match. Verify on butternut:
  #   doas cat /run/secrets/nix-serve-secret-key | nix key convert-secret-to-public
  flake.nixServeKeys = {
    butternut = "butternut:uXXUBdRO9KP5DDdmrN80171HDGjqRB5zsey1I7Db8XM=";
  };

  # Local binary cache served by harmonia (was nix-serve-ng; the feature keeps
  # its name), signing with the per-host key from
  # secrets/<hostname>/nix-serve.yaml (key `nix-serve-secret-key`; same key
  # format, so clients' trusted key is unchanged).
  #
  # Why harmonia: transparent zstd compression (2-3x less data over Wi-Fi),
  # store access through the nix daemon, and it advertises priority 30 in
  # /nix-cache-info, which beats cache.nixos.org (40) without a `?priority=`.
  #
  # Requires: sops module imported on the host.
  flake.nixosModules.nix-serve = {
    config,
    lib,
    ...
  }: let
    cfg = config.preferences.nix-serve;
    port = 5000;
  in {
    options.preferences.nix-serve.firewallInterfaces = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = ["eno2"];
      description = ''
        Interfaces on which the cache port is opened. `null` opens it on
        every interface. (Tailscale is a trusted interface either way.)
      '';
    };

    config = {
      sops.secrets."nix-serve-secret-key" = {
        sopsFile = ../../.. + "/secrets/${config.networking.hostName}/nix-serve.yaml";
        # harmonia uses DynamicUser and reads the key via LoadCredential (as root).
        owner = "root";
        mode = "0400";
        restartUnits = ["harmonia.service"];
      };

      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [config.sops.secrets."nix-serve-secret-key".path];
        settings = {
          bind = "[::]:${toString port}";
          priority = 30;
          # Incompatible with resuming interrupted downloads; fine on LAN,
          # cable and tailnet.
          enable_compression = true;
        };
      };

      networking.firewall.allowedTCPPorts = lib.mkIf (cfg.firewallInterfaces == null) [port];
      networking.firewall.interfaces = lib.mkIf (cfg.firewallInterfaces != null) (
        lib.genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [port];
        })
      );
    };
  };
}
