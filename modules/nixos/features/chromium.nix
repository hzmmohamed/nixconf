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
      #
      # WebGPU: Chromium keeps it off on Linux unless its Vulkan backend is
      # on; the chrome://flags "Unsafe WebGPU" switch only gave SwiftShader
      # (CPU) plus an unsupported-flag warning on every start. `Vulkan` is a
      # plain feature (no warning): real GPU adapter, checked on butternut
      # (NVIDIA Ampere). Chromium honours only the last --enable-features, so
      # this repeats the NixOS wrapper's WaylandWindowDecorations.
      commandLineArgs = [
        "--password-store=gnome-libsecret"
        "--enable-features=WaylandWindowDecorations,Vulkan"
      ];
      extensions = [
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
