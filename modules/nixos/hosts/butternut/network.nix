{
  # butternut travels to offices and cafés: only advertise itself over mDNS on
  # the direct ethernet link to hazel, not on whatever Wi-Fi it joins.
  flake.nixosModules.hostButternut = {
    preferences.lan-discovery.interfaces = ["eno2"];
  };
}
