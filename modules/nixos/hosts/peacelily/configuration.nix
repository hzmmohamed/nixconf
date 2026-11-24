{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.peacelily = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostPeacelily
    ];
  };

  # peacelily: headless, always-on GPU AI server at home (RTX 5060 Ti 16 GB):
  # llama-swap, Wyoming STT/TTS, Qdrant, LibreChat, Prometheus + Grafana.
  # No desktop stack; reach it over SSH (port 7654) or Tailscale SSH.
  # Bring-up: docs/plans/2026-11-24-peacelily-bring-up.md.
  flake.nixosModules.hostPeacelily = {...}: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general

      self.nixosModules.nvidia
      self.nixosModules.ai-server

      self.nixosModules.sops
      self.nixosModules.openssh
      self.nixosModules.wifi-home
      self.nixosModules.tailscale
      self.nixosModules.doas

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostPeacelily
    ];

    boot = {
      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.systemd-boot.editor = false;
      loader.efi.canTouchEfiVariables = true;

      kernelParams = ["quiet"];
    };

    networking = {
      hostName = "peacelily";
      networkmanager.enable = true;
    };

    # Stationary home server: LAN service ports on every interface (the AI
    # services themselves stay tailscale0-only, ai-server.nix).
    preferences.trustedNetworks.everywhere = true;

    # Tagged login via the OAuth client once secrets/shared/tailscale-oauth.yaml
    # exists (tags from the hosts registry); shared auth key until then.
    preferences.tailscale.oauth.enable = true;

    hardware.cpu.intel.updateMicrocode = true;

    # Compute-only GPU: keep it initialized between jobs (no cold start for
    # the first CUDA call, nvidia-smi answers instantly).
    hardware.nvidia.nvidiaPersistenced = true;

    services.journald.extraConfig = ''
      SystemMaxUse=1G
      MaxRetentionSec=1month
    '';

    # Never sleep, whatever asks for it.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };

    time.timeZone = "Africa/Cairo";

    programs.nix-ld.enable = true;

    system.stateVersion = "24.11";
  };
}
