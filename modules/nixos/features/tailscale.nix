{...}: {
  flake.nixosModules.tailscale = {config, ...}: let
    user = config.preferences.user.name;
  in {
    home-manager.users.${user} = {
      services.tailscale-systray.enable = true;
    };

    services.tailscale = {
      enable = true;
      extraUpFlags = ["--ssh"];
      authKeyFile = config.sops.secrets."tailscale_authkey".path;
    };

    sops.secrets."tailscale_authkey" = {
      sopsFile = ../../../secrets/shared/tailscale.yaml;
    };

    networking.firewall = {
      trustedInterfaces = [config.services.tailscale.interfaceName];
      checkReversePath = "loose";
      allowedUDPPorts = [config.services.tailscale.port];
      allowedTCPPorts = [22];
    };
  };
}
