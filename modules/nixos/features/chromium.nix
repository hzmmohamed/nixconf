{
  flake.nixosModules.chromium = {pkgs, ...}: {
    programs.chromium = {
      enable = true;
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

    environment.systemPackages = [
      pkgs.ungoogled-chromium
    ];

    persistance.cache.directories = [
      ".config/chromium"
    ];
  };
}
