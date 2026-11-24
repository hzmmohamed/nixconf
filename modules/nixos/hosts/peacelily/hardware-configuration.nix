{
  # PLACEHOLDER: generic modules, never generated on the machine. Replace with
  #   ssh -p 7654 peacelily nixos-generate-config --show-hardware-config --no-filesystems
  # (filesystems come from disko.nix). Runbook:
  # docs/plans/2026-11-24-peacelily-bring-up.md.
  flake.nixosModules.hostPeacelily = {
    config,
    lib,
    modulesPath,
    ...
  }: {
    imports = [
      (modulesPath + "/installer/scan/not-detected.nix")
    ];

    boot.initrd.availableKernelModules = ["xhci_pci" "thunderbolt" "nvme" "usb_storage" "sd_mod"];
    boot.initrd.kernelModules = [];
    boot.extraModulePackages = [];

    networking.useDHCP = lib.mkDefault true;

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
