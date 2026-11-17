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

      self.nixosModules.powersave

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

    boot.plymouth.enable = true;

    networking = {
      hostName = "peacelily";
      networkmanager.enable = true;
    };

    hardware.cpu.intel.updateMicrocode = true;

    programs.nix-ld.enable = true;

    system.stateVersion = "24.11";
  };
}
