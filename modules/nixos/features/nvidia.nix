{...}: {
  flake.nixosModules.nvidia = {pkgs, ...}: {
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    services.xserver.videoDrivers = ["nvidia"];

    hardware.nvidia = {
      modesetting.enable = true;
      open = true;
      powerManagement.enable = true;
      nvidiaSettings = false;
    };

    hardware.nvidia-container-toolkit.enable = true;

    boot.kernelPackages = pkgs.linuxPackages_latest;
  };
}
