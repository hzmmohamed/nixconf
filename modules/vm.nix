{
  inputs,
  self,
  ...
}: {
  # VM configuration for testing butternut host
  # Build with: nix build .#nixosConfigurations.butternut-vm.config.system.build.vm
  # Run with:   ./result/bin/run-butternut-vm-vm
  flake.nixosConfigurations.butternut-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.sway
      self.nixosModules.swayidle
      self.nixosModules.cliphist
      self.nixosModules.waybar

      self.nixosModules.discord
      self.nixosModules.gimp
      self.nixosModules.telegram
      self.nixosModules.youtube-music

      self.nixosModules.powersave

      ({pkgs, lib, modulesPath, ...}: {
        imports = [
          (modulesPath + "/profiles/qemu-guest.nix")
        ];

        nixpkgs.hostPlatform = "x86_64-linux";

        networking.hostName = "butternut-vm";
        networking.networkmanager.enable = true;

        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.kernelPackages = pkgs.linuxPackages_latest;

        # VM needs a simple filesystem, not disko/LUKS
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };

        # Override hashedPasswordFile from general.nix — no /persist in VM
        users.users.yurii.hashedPasswordFile = lib.mkForce null;
        users.users.yurii.initialPassword = lib.mkForce "test";

        hardware.graphics.enable = true;

        system.stateVersion = "23.05";
      })
    ];
  };
}
