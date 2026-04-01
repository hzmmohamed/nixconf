{
  flake.nixosModules.chromium = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    home-manager.users.${user}.programs.chromium = {
      enable = true;
      package = pkgs.ungoogled-chromium;
      extensions = [
        {id = "nngceckbapebfimnlniiiahkandclblb";} # Bitwarden
        {id = "chphlpgkkbolifaimnlloiipkdnihall";} # OneTab
        {id = "ekhagklcjbdpajgpjgmbionohlpdbjgc";} # Zotero Connector
        {id = "ghbmnnjooekpmoecnnnilnnbdlolhkhi";} # Google Docs Offline
        {id = "pmjeegjhjdlccodhacdgbgfagbpmccpe";} # Clockify Time Tracker
        {id = "nglaklhklhcoonedhgnpgddginnjdadi";} # Activity Watcher
        {id = "fpnmgdkabkmnadcjpehmlllkndpkmiak";} # Wayback Machine
        {id = "bcjindcccaagfpapjjmafapmmgkkhgoa";} # JSON Formatter
      ];
    };

    persistance.cache.directories = [
      ".config/chromium"
    ];
  };
}
