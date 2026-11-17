{self, ...}: {
  flake.nixosModules.syncthing = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
    group = config.users.users.${user}.group;
    hostname = config.networking.hostName;
    secretsFile = ../../.. + "/secrets/${hostname}/syncthing.yaml";
    guiFromSops = config.preferences.syncthing.guiPasswordFromSops;

    # Device IDs live in the hosts registry (modules/hosts-registry.nix).
    # Addresses: the cable when both ends have one, then the registry name
    # (/etc/hosts → tailnet IP, works with MagicDNS off), then discovery.
    me = self.hosts.${hostname} or {};
    peers = lib.filterAttrs (_: h: (h.syncthingId or null) != null) self.hosts;
    deviceFor = n: h: {
      id = h.syncthingId;
      addresses =
        lib.optional ((me.cable or null) != null && (h.cable or null) != null && n != hostname)
        "tcp://${h.cable}:22000"
        ++ ["tcp://${n}:22000" "quic://${n}:22000" "dynamic"];
    };
  in {
    options.preferences.syncthing.guiPasswordFromSops = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Read the Syncthing GUI password (plaintext; hashed by syncthing-init)
        from the sops secret `syncthing-gui-password` in
        secrets/shared/user.yaml instead of the committed placeholder.
      '';
    };

    config = {
      sops.secrets."syncthing-gui-password" = lib.mkIf guiFromSops {
        sopsFile = ../../.. + "/secrets/shared/user.yaml";
        # syncthing-init runs as the syncthing user and reads this file.
        owner = user;
        inherit group;
        mode = "0400";
        restartUnits = ["syncthing-init.service"];
      };

      sops.secrets."syncthing/key" = {
        sopsFile = secretsFile;
        owner = user;
        inherit group;
        mode = "0400";
        restartUnits = ["syncthing.service"];
      };
      sops.secrets."syncthing/cert" = {
        sopsFile = secretsFile;
        owner = user;
        inherit group;
        mode = "0400";
        restartUnits = ["syncthing.service"];
      };

      services.syncthing = {
        enable = true;
        inherit user group;
        dataDir = config.users.users.${user}.home;
        # Sync/discovery ports on trusted networks only (below); peers on
        # other networks connect over the tailnet.
        openDefaultPorts = false;

        key = config.sops.secrets."syncthing/key".path;
        cert = config.sops.secrets."syncthing/cert".path;

        guiPasswordFile = lib.mkIf guiFromSops config.sops.secrets."syncthing-gui-password".path;

        settings = {
          gui =
            {
              inherit user;
            }
            # GUI listens on 127.0.0.1:8384 only. TODO: drop this placeholder
            # once guiPasswordFromSops is enabled everywhere.
            // lib.optionalAttrs (!guiFromSops) {
              password = "password";
            };

          devices = lib.mapAttrs deviceFor peers;
        };
      };

      # 22000 TCP (sync) + UDP (QUIC), 21027 UDP (local discovery).
      preferences.trustedNetworks = {
        allowedTCPPorts = [22000];
        allowedUDPPorts = [22000 21027];
      };

      systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true";
    };
  };
}
