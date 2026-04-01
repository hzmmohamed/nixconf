{inputs, ...}: {
  flake.nixosModules.firefox = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    programs.firefox.enable = true;

    home-manager.users.${user}.programs.firefox = {
      enable = true;
      profiles.${user} = {
        extensions.packages = with inputs.firefox-addons.packages.${pkgs.system}; [
          bitwarden
          tree-style-tab
          zotero-connector
        ];
      };
    };

    persistance.data.directories = [
      ".mozilla"
    ];

    persistance.cache.directories = [
      ".cache/mozilla"
    ];

    preferences.keymap = {
      "SUPER + d"."f".package = pkgs.firefox;
    };
  };
}
