# Spotify Connect receiver (spotifyd) — no GUI client. Control it from the
# phone/desktop Spotify app ("<hostname>" device) and from the bar/media keys:
# spotifyd exposes MPRIS on the session bus, so playerctl, the waybar mpris
# module and Noctalia's media widget all see it.
#
# First login: pick the device in the Spotify app once (zeroconf hands over
# credentials, cached in ~/.cache/spotifyd), or run `spotifyd-login`.
{
  flake.nixosModules.spotify = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    zeroconfPort = 57622;
    spotifyd = lib.getExe pkgs.spotifyd;
    configFile = (pkgs.formats.toml {}).generate "spotifyd.conf" {
      global = {
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

    # The only CLI on PATH: (re)authenticate the service's own account with
    # its config and cache, then restart it. A bare `spotifyd` is not on
    # PATH on purpose: run by hand it becomes a second, unconfigured
    # receiver (no PulseAudio, no MPRIS) that Spotify happily connects to.
    spotifydLogin = pkgs.writeShellApplication {
      name = "spotifyd-login";
      runtimeInputs = [pkgs.systemd];
      text = ''
        systemctl --user stop spotifyd.service || true
        trap 'systemctl --user start spotifyd.service' EXIT
        ${spotifyd} authenticate --config-path ${configFile} "$@"
      '';
    };
  in {
    # Own unit instead of home-manager's services.spotifyd, which also puts
    # spotifyd on PATH. Same settings and ExecStart as that module.
    home-manager.users.${user} = {
      home.packages = [spotifydLogin];
      systemd.user.services.spotifyd = {
        Unit = {
          Description = "Spotify Connect receiver (spotifyd)";
          After = ["pipewire-pulse.service"];
        };
        Service = {
          # Wait (max 30 s) for a network at login instead of crashing once
          # (exit 101) and restarting 12 s later.
          ExecStartPre = "-${pkgs.networkmanager}/bin/nm-online -q -t 30";
          ExecStart = "${spotifyd} --no-daemon --config-path ${configFile}";
          Restart = "always";
          RestartSec = 12;
        };
        Install.WantedBy = ["default.target"];
      };
    };

    # Spotify Connect discovery: spotifyd answers mDNS itself (libmdns, no
    # avahi needed) on UDP 5353 and serves the zeroconf endpoint on TCP.
    # Trusted networks only: on café Wi-Fi the device is not advertised (it
    # still works through the Spotify account / cloud discovery).
    preferences.trustedNetworks = {
      allowedUDPPorts = [5353];
      allowedTCPPorts = [zeroconfPort];
    };

    # Credentials + audio cache survive reboots on impermanent hosts.
    persistance.cache.directories = [".cache/spotifyd"];
  };
}
