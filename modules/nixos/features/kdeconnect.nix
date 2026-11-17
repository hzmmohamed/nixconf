{...}: {
  flake.nixosModules.kdeconnect = {config, ...}: let
    user = config.preferences.user.name;
  in {
    # KDEConnect uses UDP 1716 for discovery and TCP 1714-1764 for data.
    # Trusted networks only (home/hotspot Wi-Fi, cable, tailscale0): never
    # announced to strangers on café Wi-Fi. From anywhere, pair the phone
    # "by IP" with the tailnet address (hosts registry).
    preferences.trustedNetworks = {
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

      # KDE Connect needs WAYLAND_DISPLAY which is only available after sway
      # imports the environment. Wait for sway-session.target.
      systemd.user.services.kdeconnect = {
        Unit = {
          After = ["sway-session.target"];
          PartOf = ["graphical-session.target"];
          Requisite = ["sway-session.target"];
        };
      };
      systemd.user.services.kdeconnect-indicator = {
        Unit = {
          After = ["sway-session.target"];
          PartOf = ["graphical-session.target"];
          Requisite = ["sway-session.target"];
        };
      };
    };
  };
}
