{...}: {
  flake.nixosModules.wifi-home = {config, ...}: {
    sops.secrets."wifi_env" = {
      sopsFile = ../../../secrets/shared/wifi.yaml;
    };

    networking.networkmanager.ensureProfiles.environmentFiles = [
      config.sops.secrets."wifi_env".path
    ];

    networking.networkmanager.ensureProfiles.profiles.home = {
      connection = {
        id = "home";
        type = "wifi";
        autoconnect = true;
      };
      wifi = {
        ssid = "home";
        mode = "infrastructure";
      };
      wifi-security = {
        key-mgmt = "wpa-psk";
        psk = "$WIFI_HOME_PSK";
      };
    };
  };
}
