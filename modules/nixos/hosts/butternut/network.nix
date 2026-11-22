{
  flake.nixosModules.hostButternut = {
    # mDNS on eno2 only (the cable, or the home LAN). Not on Wi-Fi (wlo1):
    # UDP 5353 is open only on trusted networks (cable, home router, home
    # Wi-Fi), the hotspot and café/office Wi-Fi are not, and avahi would still
    # announce `butternut.local` there (lan-discovery.nix).
    preferences.lan-discovery.interfaces = ["eno2"];

    # Wi-Fi profiles beyond home (secrets: see features/wifi-home.nix). The
    # hotspot autoconnects (untrusted, metered): headless at a café,
    # butternut's agents need it.
    preferences.wifi = {
      hotspot.enable = true;
      office.enable = true;
    };
  };
}
