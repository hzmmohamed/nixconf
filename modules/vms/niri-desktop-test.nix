{
  inputs,
  self,
  ...
}: {
  # Niri Desktop VM — for testing Niri + Noctalia desktop experience
  # Build: nix build .#nixosConfigurations.niri-desktop-vm.config.system.build.vm
  # Run:   QEMU_OPTS="-device virtio-vga-gl -display gtk,gl=on" ./result/bin/run-niri-desktop-vm-vm
  flake.nixosConfigurations.niri-desktop-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.niri-desktop

      self.nixosModules.powersave

      ({
        pkgs,
        lib,
        config,
        modulesPath,
        ...
      }: let
        user = config.preferences.user.name;
      in {
        imports = [
          (modulesPath + "/profiles/qemu-guest.nix")
        ];

        nixpkgs.hostPlatform = "x86_64-linux";

        networking.hostName = "niri-desktop-vm";
        networking.networkmanager.enable = true;

        boot.loader.systemd-boot.enable = true;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.kernelPackages = pkgs.linuxPackages_latest;

        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };

        users.users.${user} = {
          hashedPasswordFile = lib.mkForce null;
          initialPassword = lib.mkForce "test";
        };

        # Auto-login into Niri
        services.greetd = {
          enable = true;
          settings.default_session = {
            command = "${config.programs.niri.package}/bin/niri-session";
            inherit user;
          };
        };

        hardware.graphics.enable = true;

        # vmVariant re-evaluates and loses the wrapped niri passthru;
        # override its session package to avoid the providedSessions check.
        virtualisation.vmVariant.programs.niri.package = lib.mkForce pkgs.niri;

        system.stateVersion = "23.05";
      })
    ];
  };
}
