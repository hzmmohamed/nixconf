{...}: {
  # Shared Zotero library across hosts.
  # Installs Zotero and optionally syncs its database and attachments
  # between hosts via Syncthing.
  #
  # When sharing is enabled (default), this module:
  # 1. Declares Syncthing folders for zotero-db and zotero-attachments
  # 2. Declares sops secrets for syncthing credentials, resolved per-host
  #    from secrets/<hostname>/syncthing.yaml
  #
  # Requires: syncthing and sops modules imported on the host.
  flake.nixosModules.shared-zotero = {
    config,
    lib,
    pkgs,
    ...
  }: let
    home = config.users.users.${config.preferences.user.name}.home;
    user = config.preferences.user.name;
    hostname = config.networking.hostName;
    secretsFile = ../../.. + "/secrets/${hostname}/syncthing.yaml";
  in {
    options.preferences.zotero.sharing = lib.mkEnableOption "Zotero library sharing via Syncthing" // {default = true;};

    config = {
      environment.systemPackages = [pkgs.zotero];

      # When sharing is enabled, wire up syncthing folders and secrets
      services.syncthing.settings.folders = lib.mkIf config.preferences.zotero.sharing {
        "zotero-db" = {
          path = "${home}/Zotero";
          devices = ["butternut" "maple"];
          ignorePerms = false;
        };
        "zotero-attachments" = {
          path = "${home}/personal/zotero-attachments";
          devices = ["butternut" "maple"];
          ignorePerms = false;
        };
      };

      # Syncthing credentials — resolved per-host from secrets/<hostname>/
      sops.secrets = lib.mkIf config.preferences.zotero.sharing {
        "syncthing/key" = {
          sopsFile = secretsFile;
          owner = user;
          group = config.users.users.${user}.group;
          mode = "0400";
          restartUnits = ["syncthing.service"];
        };
        "syncthing/cert" = {
          sopsFile = secretsFile;
          owner = user;
          group = config.users.users.${user}.group;
          mode = "0400";
          restartUnits = ["syncthing.service"];
        };
      };
    };
  };
}
