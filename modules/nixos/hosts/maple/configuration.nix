{
  inputs,
  self,
  ...
}: {
  flake.nixosConfigurations.maple = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.hostMaple
    ];
  };

  # maple: laptop whose screen died — runs headless as an always-on node
  # (lid closed, on AC). No desktop stack; reach it over SSH (port 7654) or
  # Tailscale SSH.
  flake.nixosModules.hostMaple = {
    config,
    pkgs,
    ...
  }: {
    imports = [
      self.nixosModules.base
      self.nixosModules.general

      self.nixosModules.sops
      self.nixosModules.openssh
      self.nixosModules.tailscale
      self.nixosModules.syncthing
      self.nixosModules.vault
      self.nixosModules.nix-serve
      self.nixosModules.doas

      # CLI / server tooling
      self.nixosModules.docker
      self.nixosModules.k8s
      self.nixosModules.aws
      self.nixosModules.atuin
      self.nixosModules.zellij
      self.nixosModules.yazi
      self.nixosModules.gpg
      self.nixosModules.nodejs

      # disko
      inputs.disko.nixosModules.disko
      self.diskoConfigurations.hostMaple
    ];

    boot = {
      kernelPackages = pkgs.linuxPackages_latest;

      loader.systemd-boot.enable = true;
      loader.systemd-boot.configurationLimit = 5;
      loader.systemd-boot.editor = false;
      loader.efi.canTouchEfiVariables = true;

      kernelParams = ["quiet"];
    };

    networking = {
      hostName = "maple";
      networkmanager.enable = true;
    };

    hardware.cpu.intel.updateMicrocode = true;

    services = {
      udisks2.enable = true;
      thermald.enable = true;

      # Laptop-as-server: closing the lid must never suspend.
      logind.settings.Login = {
        HandleLidSwitch = "ignore";
        HandleLidSwitchExternalPower = "ignore";
        HandleLidSwitchDocked = "ignore";
      };

      journald.extraConfig = ''
        SystemMaxUse=1G
        MaxRetentionSec=1month
      '';
    };

    # Never sleep, whatever asks for it.
    systemd.targets = {
      sleep.enable = false;
      suspend.enable = false;
      hibernate.enable = false;
      hybrid-sleep.enable = false;
    };

    # Keep user services (agents, zellij sessions) running without a login.
    users.users.${config.preferences.user.name}.linger = true;

    programs.nix-ld.enable = true;

    time.timeZone = "Africa/Cairo";

    # Always-on copy of the vault (Syncthing folder only, no KeePassXC here):
    # a year of staggered versions is the vault's history/backup.
    preferences.vault.keepVersions = true;

    system.stateVersion = "24.11";
  };
}
