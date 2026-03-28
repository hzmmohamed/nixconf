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
      # Import the full butternut host module
      self.nixosModules.hostButternut

      ({pkgs, lib, config, modulesPath, ...}: let
        user = config.preferences.user.name;
      in {
        imports = [
          (modulesPath + "/profiles/qemu-guest.nix")
        ];

        # VM overrides
        disabledModules = [];
        nixpkgs.hostPlatform = lib.mkForce "x86_64-linux";
        networking.hostName = lib.mkForce "butternut-vm";

        # Replace butternut's boot config
        boot.loader.systemd-boot.enable = lib.mkForce true;
        boot.loader.efi.canTouchEfiVariables = lib.mkForce true;
        boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;
        boot.kernelParams = lib.mkForce ["quiet"];
        boot.kernelModules = lib.mkForce [];
        boot.plymouth.enable = lib.mkForce false;
        boot.initrd.availableKernelModules = lib.mkForce ["virtio_pci" "virtio_blk" "virtio_net"];

        # VM filesystem instead of disko/LUKS
        disko.devices = lib.mkForce {};
        fileSystems = lib.mkForce {
          "/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
        };

        # No /persist in VM
        users.users.${user} = {
          hashedPasswordFile = lib.mkForce null;
          initialPassword = lib.mkForce "test";
        };

        # Auto-login for quick VM testing (butternut uses tuigreet instead)
        services.greetd = lib.mkForce {
          enable = true;
          settings.default_session = {
            command = "${pkgs.sway}/bin/sway";
            inherit user;
          };
        };

        # Disable hardware-specific services
        hardware.cpu.intel.updateMicrocode = lib.mkForce false;
        services.asusd.enable = lib.mkForce false;
        services.asusd.enableUserService = lib.mkForce false;

        system.stateVersion = lib.mkForce "23.05";
      })
    ];
  };
}
