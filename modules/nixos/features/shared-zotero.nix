{...}: {
  # Shared Zotero library across hosts.
  # Installs Zotero and optionally syncs its database and attachments
  # between hosts via Syncthing.
  #
  # When sharing is enabled (default), this module declares Syncthing folders
  # for zotero-db and zotero-attachments.
  #
  # Requires: syncthing and sops modules imported on the host.
  flake.nixosModules.shared-zotero = {
    config,
    lib,
    pkgs,
    ...
  }: let
    home = config.users.users.${config.preferences.user.name}.home;
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
    };
  };
}
