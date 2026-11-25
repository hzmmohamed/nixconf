# butternut dual-mode boot: desktop with an external monitor, or headless
# (café / portable compute). Feature: modules/nixos/features/headless-boot.nix.
# Enable sequence + troubleshooting: docs/plans/2026-11-17-network-review.md,
# "Implemented — headless boot". Do the steps IN ORDER; each risky part stays
# off until the previous one was tested with a screen attached.
{self, ...}: {
  flake.nixosModules.hostButternut = {config, ...}: {
    imports = [self.nixosModules.headless-boot self.nixosModules.headless-modes];

    # Mode from "external display?" + "on AC?": desk / headless (built-in
    # keyboard muted) / bag (also CPU capped, power-saver). It also sets the
    # ppd profile (performance outside bag). `headless-mode status`.
    preferences.headlessModes.enable = true;

    preferences.headlessBoot = {
      # Active now (harmless): lid switch ignored (broken panel, always on AC),
      # user lingering (agent-host already sets it too).
      enable = true;

      # Stick enrolled 2026-11-17 (16 GB SanDisk, vfat label BNKEY, extra
      # LUKS slot). Password fallback after 10 s stays in place regardless.
      usbKeyfile = {
        enable = true;
        deviceUuid = "12CE-A600";
        path = "/butternut.key";
        fsType = "vfat";
      };

      # No external monitor at boot: greetd is skipped and the keyboard
      # backlight goes dark; plugging a monitor in starts the greeter.
      # Override: `doas touch /run/headless-boot/force-greeter`.
      detectDisplay.enable = true;

      # TODO(step 5): generate /etc/secrets/initrd/ssh_host_ed25519_key first
      # and add hazel's key to modules/ssh-keys.nix, then enable.
      initrdSsh = {
        enable = false;
        macAddress = "a0:36:bc:30:d3:e3"; # eno2 (e1000e)
      };

      # On automatically once ntfy is enabled for the agents (sops topic).
      notify.enable = config.preferences.agents.ntfy.topicFile != null;
    };
  };
}
