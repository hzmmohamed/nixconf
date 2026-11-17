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
      # Under Sway (XDG_CURRENT_DESKTOP=sway) Chromium has to guess the
      # password store; pin it to the gnome-keyring Secret Service, where the
      # existing "Chromium Safe Storage" key (login collection) lives.
      commandLineArgs = ["--password-store=gnome-libsecret"];
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
