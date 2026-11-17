# OpenRGB without the always-running SDK server.
#
# The upstream service (`openrgb --server`) polls devices continuously, so it
# is kept installed (udev rules, i2c modules, unit file) but not started at
# boot — start it on demand with `sudo systemctl start openrgb` (e.g. before
# using the GUI as a client), or just run `openrgb` (GUI) directly.
#
# Instead, a oneshot applies a saved profile from ~/.config/OpenRGB at boot
# and after resume, then exits:
#   preferences.openrgb.profile = "night-time-coding";
{...}: {
  flake.nixosModules.openrgb = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.services.hardware.openrgb;
    user = config.preferences.user.name;
    home = config.users.users.${user}.home;
    profile = config.preferences.openrgb.profile;
  in {
    options.preferences.openrgb.profile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "night-time-coding";
      description = ''
        OpenRGB profile (file name in ~/.config/OpenRGB, with or without
        `.orp`) applied by a oneshot at boot and after resume. null disables
        the oneshot.
      '';
    };

    config = {
      services.hardware.openrgb.enable = true;

      # Keep the unit available but don't start the polling server at boot.
      systemd.services.openrgb.wantedBy = lib.mkForce [];

      systemd.services.openrgb-profile = lib.mkIf (profile != null) {
        description = "Apply OpenRGB profile ${profile}";
        wantedBy = ["multi-user.target" "post-resume.target"];
        after = ["systemd-udev-trigger.service" "post-resume.target"];
        serviceConfig = {
          Type = "oneshot";
          # Skip if the server was started manually (it owns the devices).
          ExecCondition = "${pkgs.bash}/bin/sh -c '! ${pkgs.systemd}/bin/systemctl is-active --quiet openrgb.service'";
          # The openrgb udev rules make the LED sysfs nodes / HID devices
          # user-writable, so this runs as the user (keeps ~/.config/OpenRGB
          # user-owned; openrgb writes logs there).
          User = user;
          ExecStart = lib.escapeShellArgs [
            (lib.getExe cfg.package)
            "--noautoconnect"
            "--config"
            "${home}/.config/OpenRGB"
            "--profile"
            profile
          ];
        };
      };
    };
  };
}
