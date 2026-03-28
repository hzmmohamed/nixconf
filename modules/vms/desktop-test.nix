{
  inputs,
  self,
  ...
}: {
  # Desktop VM — for testing Sway, waybar, and the desktop experience
  # Build: nix build .#nixosConfigurations.desktop-vm.config.system.build.vm
  # Run:   ./result/bin/run-desktop-vm-vm
  flake.nixosConfigurations.desktop-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.base
      self.nixosModules.general
      self.nixosModules.desktop

      self.nixosModules.sway
      self.nixosModules.swayidle
      self.nixosModules.cliphist
      self.nixosModules.gammastep
      self.nixosModules.waybar

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

        networking.hostName = "desktop-vm";
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

        # Auto-login into Sway
        services.greetd = {
          enable = true;
          settings.default_session = {
            command = "${pkgs.sway}/bin/sway";
            inherit user;
          };
        };

        hardware.graphics.enable = true;

        system.stateVersion = "23.05";
      })
    ];
  };
}
