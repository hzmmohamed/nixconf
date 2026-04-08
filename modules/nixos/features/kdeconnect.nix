{...}: {
  flake.nixosModules.kdeconnect = {config, ...}: let
    user = config.preferences.user.name;
  in {
    # KDEConnect uses UDP 1716 for discovery and TCP 1714-1764 for data
    networking.firewall = {
      allowedTCPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
      allowedUDPPortRanges = [
        {
          from = 1714;
          to = 1764;
        }
      ];
    };

    home-manager.users.${user} = {
      services.kdeconnect = {
        enable = true;
        indicator = true;
      };
    };
  };
}
