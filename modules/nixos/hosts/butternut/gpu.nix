{self, ...}: {
  # butternut (ASUS TUF F15 FX507ZC): Intel Alder Lake iGPU drives the
  # (external) display; the RTX 3050 Laptop dGPU is kept awake for CUDA
  # compute and PRIME render offload. The internal panel is broken and the
  # machine is always on AC, so it is treated as a desktop (no dGPU RTD3).
  flake.nixosModules.hostButternut = {
    lib,
    pkgs,
    ...
  }: {
    # Shared driver base (open kernel modules, container toolkit, latest kernel).
    imports = [self.nixosModules.nvidia];

    hardware.nvidia = {
      prime = {
        offload.enable = true;
        offload.enableOffloadCmd = true; # provides `nvidia-offload <cmd>`
        intelBusId = "PCI:0:2:0";
        nvidiaBusId = "PCI:1:0:0";
      };

      # No RTD3 runtime suspend: keep the dGPU initialized for compute.
      powerManagement.finegrained = false;
      nvidiaPersistenced = true;

      # The dGPU drives no display here; don't let nvidia-drm register a
      # framebuffer that could steal fbcon/the greeter TTY from i915.
      moduleParams.nvidia-drm.fbdev = lib.mkForce 0;
    };

    # Load i915 early so the iGPU is always the primary framebuffer (fb0).
    boot.initrd.kernelModules = ["i915"];

    # powertop --auto-tune (from the powersave module) flips every PCI device
    # to power/control=auto, which runtime-suspends the dGPU. Not needed on a
    # desktop-like machine; also pin NVIDIA functions to "on" via udev.
    powerManagement.powertop.enable = lib.mkForce false;
    services.udev.extraRules = ''
      ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", TEST=="power/control", ATTR{power/control}="on"

      # Stable, colon-free name for the iGPU DRM node (WLR_DRM_DEVICES is
      # colon-separated, so /dev/dri/by-path/... can't be used).
      KERNEL=="card*", SUBSYSTEM=="drm", KERNELS=="0000:00:02.0", SYMLINK+="dri/igpu"
    '';

    # Keep sway (wlroots) on the iGPU only so the compositor never holds a
    # context on the dGPU.
    environment.sessionVariables.WLR_DRM_DEVICES = "/dev/dri/igpu";

    # Small diagnostics; CUDA toolkits come per-project (see nix.nix cache).
    # No nvtop: nvtopPackages.* pull the whole CUDA toolkit. btop shows the GPU
    # via NVML at runtime, and nvidia-smi ships with the driver.
    environment.systemPackages = [
      pkgs.mesa-demos # glxinfo
      pkgs.vulkan-tools # vulkaninfo
    ];
  };
}
