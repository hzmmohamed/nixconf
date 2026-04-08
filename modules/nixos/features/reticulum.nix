{
  inputs,
  self,
  ...
}: {
  flake.nixosModules.reticulum = {
    config,
    pkgs,
    ...
  }: {
    imports = [
      # reticulum-shared declares rns.shared.* options (rnsd user service, config seeding)
      inputs.reticulum-flake.nixosModules.reticulum-shared
      # reticulum-integration adds system packages and dialout group (gated by rns.shared.enable)
      inputs.reticulum-flake.nixosModules.reticulum-integration
      inputs.reticulum-flake.nixosModules.meshchat-launchers
      # RNS Map web visualizations
      inputs.reticulum-flake.nixosModules.rns-map-service
      inputs.reticulum-flake.nixosModules.rns-map-defaults
      inputs.reticulum-flake.nixosModules.rns-map-3d-service
      inputs.reticulum-flake.nixosModules.rns-map-3d-defaults
    ];

    nixpkgs.overlays = [inputs.reticulum-flake.overlays.default];

    # Enable the shared rnsd user service
    rns.shared = {
      enable = true;
      user = config.preferences.user.name;
      configDir = ".reticulum";
      interfaces.tailscale.enable = true;
      interfaces.wan.enable = false;
      addPackages = true;
      meshchat.ensureStorage = true;
    };

    # Enable RNS Map visualizations (ports 8085 and 8086)
    rns.map.enable = false;
    rns.map3d.enable = false;

    # Add lxmf to rnsd's PYTHONPATH so discover_interfaces works
    systemd.user.services.rnsd.serviceConfig.Environment = let
      lxmfPath = "${pkgs.lxmf}/lib/python3.13/site-packages";
    in
      pkgs.lib.mkForce [
        "RNS_CONFIGDIR=%h/${config.rns.shared.configDir}"
        "PYTHONPATH=${lxmfPath}"
      ];

    # UDP ports required by Reticulum AutoInterface for local discovery
    networking.firewall.allowedUDPPorts = [29716 42671];

    # git is needed system-wide for the Nix daemon to resolve builtins.fetchGit
    # used by rns-map packages from the reticulum flake
    environment.systemPackages = [pkgs.git];

    # Meshchat packages scoped to the user + managed reticulum config
    home-manager.users.${config.preferences.user.name} = {
      home.packages = [
        self.packages.${pkgs.system}.meshchatx
        self.packages.${pkgs.system}.meshchatx-desktop-entry
      ];

      home.file.".reticulum/config".text = ''
        [reticulum]
          enable_transport = True
          share_instance = Yes
          instance_name = default
          discover_interfaces = False
          autoconnect_discovered_interfaces = 3

        [logging]
          loglevel = 4

        [interfaces]
          [[Default Interface]]
            type = AutoInterface
            enabled = Yes

          [[Helsinki_IP_RNS_Node]]
            type = TCPClientInterface
            enabled = yes
            target_host = rns.artdaw.com
            target_port = 4242
      '';
    };
  };
}
