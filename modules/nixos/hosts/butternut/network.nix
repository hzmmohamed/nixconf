{
  flake.nixosModules.hostButternut = {
    # mDNS on eno2 (the cable, or the home LAN) and Wi-Fi (wlo1:
    # `butternut.local` on the phone hotspot). UDP 5353 is only open on
    # trusted networks (trusted-networks: cable, home router, home Wi-Fi,
    # hotspot), so on café/office networks avahi stays deaf.
    preferences.lan-discovery.interfaces = ["eno2" "wlo1"];

    # Wi-Fi profiles beyond home (secrets: see features/wifi-home.nix). The
    # hotspot autoconnects: headless at a café, butternut's agents need it.
    preferences.wifi = {
      hotspot.enable = true;
      office.enable = true;
    };
  };
}
