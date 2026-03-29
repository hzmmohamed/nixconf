{...}: {
  flake.nixosModules.tailscale = {config, ...}: {
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
