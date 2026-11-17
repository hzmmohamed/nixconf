{
  # butternut is always on AC with an external monitor (broken internal
  # panel): default to the power-profiles-daemon "performance" profile at boot.
  # The shared powersave module (ppd, thermald, lact) stays as-is for laptops.
  flake.nixosModules.hostButternut = {
    lib,
    pkgs,
    ...
  }: {
    systemd.services.ppd-performance = {
      description = "Set power-profiles-daemon profile to performance";
      after = ["power-profiles-daemon.service"];
      wants = ["power-profiles-daemon.service"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.power-profiles-daemon} set performance";
      };
    };
  };
}
