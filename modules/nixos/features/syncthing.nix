{...}: {
  flake.nixosModules.syncthing = {config, ...}: let
    user = config.preferences.user.name;
    group = config.users.users.${user}.group;
    hostname = config.networking.hostName;
    secretsFile = ../../.. + "/secrets/${hostname}/syncthing.yaml";
  in {
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

      settings = {
        gui = {
          inherit user;
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
}
