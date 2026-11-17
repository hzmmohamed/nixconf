{...}: {
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
        openDefaultPorts = true;

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

          devices = {
            "butternut" = {
              id = "MRJSBVI-MRVAT7V-WHLSZBC-5LX6KFD-VGCYP4E-W265N3K-B5URBIH-RPUTWQK";
            };
            "maple" = {
              id = "H7H47TV-XI7EQDB-U4RAQWU-BYMDKVT-6HNATQP-EDELRE7-35GLDGH-BKAUBAW";
            };
          };
        };
      };

      systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true";
    };
  };
}
