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

  # Local binary cache served by nix-serve-ng, signing with the per-host key
  # from secrets/<hostname>/nix-serve.yaml (key `nix-serve-secret-key`).
  #
  # Requires: sops module imported on the host.
  flake.nixosModules.nix-serve = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.nix-serve;
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
        # nix-serve uses DynamicUser and reads the key via LoadCredential (as root).
        owner = "root";
        mode = "0400";
        restartUnits = ["nix-serve.service"];
      };

      services.nix-serve = {
        enable = true;
        package = pkgs.nix-serve-ng;
        openFirewall = cfg.firewallInterfaces == null;
        secretKeyFile = config.sops.secrets."nix-serve-secret-key".path;
      };

      networking.firewall.interfaces = lib.mkIf (cfg.firewallInterfaces != null) (
        lib.genAttrs cfg.firewallInterfaces (_: {
          allowedTCPPorts = [config.services.nix-serve.port];
        })
      );
    };
  };
}
