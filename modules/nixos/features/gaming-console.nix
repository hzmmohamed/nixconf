{self, ...}: {
  flake.nixosModules.gaming-console = {
    config,
    pkgs,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    imports = [
      self.nixosModules.gaming
      self.nixosModules.pipewire
    ];

    # Gamescope as standalone compositor running Steam Big Picture
    programs.gamescope.enable = true;

    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.gamescope}/bin/gamescope -e -f --adaptive-sync -- steam -gamepadui -steamos";
        inherit user;
      };
    };

    # Steam needs these
    hardware.graphics.enable = lib.mkDefault true;
    programs.steam.enable = true;

    # Controller support
    hardware.steam-hardware.enable = true;
    hardware.xpadneo.enable = true;

    # Bluetooth for controllers
    hardware.bluetooth.enable = lib.mkDefault true;
    hardware.bluetooth.powerOnBoot = lib.mkDefault true;

    # Xbox controller udev rules
    services.udev.extraRules = ''
      # Xbox One S / X wireless via USB
      SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="02ea", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTR{idVendor}=="045e", ATTR{idProduct}=="0b12", MODE="0660", TAG+="uaccess"
    '';

    environment.systemPackages = with pkgs; [
      xpadneo
    ];
  };
}
