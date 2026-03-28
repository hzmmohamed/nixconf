{...}: {
  flake.nixosModules.tailscale = {config, ...}: {
    services.tailscale = {
      enable = true;
      extraUpFlags = ["--ssh"];
    };

    networking.firewall = {
      trustedInterfaces = [config.services.tailscale.interfaceName];
      checkReversePath = "loose";
      allowedUDPPorts = [config.services.tailscale.port];
      allowedTCPPorts = [22];
    };
  };
}
