{...}: {
  flake.nixosModules.nvidia = {
    lib,
    pkgs,
    ...
  }: {
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

    # LTS by default: proprietary/open NVIDIA modules lag new kernels.
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;
  };
}
