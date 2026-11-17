# Spotify Connect receiver (spotifyd) — no GUI client. Control it from the
# phone/desktop Spotify app ("<hostname>" device) and from the bar/media keys:
# spotifyd exposes MPRIS on the session bus, so playerctl, the waybar mpris
# module and Noctalia's media widget all see it.
#
# First login: pick the device in the Spotify app once (zeroconf hands over
# credentials, cached in ~/.cache/spotifyd), or run `spotifyd authenticate`.
{
  flake.nixosModules.spotify = {config, ...}: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    zeroconfPort = 57622;
  in {
    home-manager.users.${user}.services.spotifyd = {
      enable = true;
      settings.global = {
        device_name = config.networking.hostName;
        device_type = "computer";
        backend = "pulseaudio";
        bitrate = 320;
        volume_normalisation = true;
        use_mpris = true;
        dbus_type = "session";
        zeroconf_port = zeroconfPort;
        cache_path = "${home}/.cache/spotifyd";
      };
    };

    # Spotify Connect discovery: spotifyd answers mDNS itself (libmdns, no
    # avahi needed) on UDP 5353 and serves the zeroconf endpoint on TCP.
    networking.firewall = {
      allowedUDPPorts = [5353];
      allowedTCPPorts = [zeroconfPort];
    };

    # Credentials + audio cache survive reboots on impermanent hosts.
    persistance.cache.directories = [".cache/spotifyd"];
  };
}
