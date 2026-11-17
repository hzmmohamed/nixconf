# Noctalia shell-wide settings. Everything the rest of the repo already
# provides stays with the repo: wallpaper (awww), lock (swaylock), idle
# (swayidle), clipboard (vicinae), night light (gammastep), launcher (vicinae).
{self, ...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    config = lib.mkIf (config.preferences.desktopShell == "noctalia") {
      home-manager.users.${user}.programs.noctalia.settings = {
        shell = {
          font_family = self.fonts.sansSerif;
          telemetry_enabled = false;
          clipboard_enabled = false;
          polkit_agent = false;
          time_format = "{:%H:%M}";
          launch_apps_as_systemd_services = true;
          animation = {
            enabled = true;
            speed = 1.5;
          };
          panel = {
            transparency_mode = "solid";
            shadow = false;
            borders = true;
            border_color = "outline_variant";
          };
        };

        backdrop.enabled = false;
        wallpaper.enabled = false;
        lockscreen.enabled = false;
        desktop_widgets.enabled = false;
        dock.enabled = false;
        nightlight.enabled = false;
        weather.enabled = false;
        calendar.enabled = false;

        idle.behavior = {
          lock.enabled = false;
          screen-off.enabled = false;
        };

        # Slow sampling: warnings only need coarse data.
        system.monitor = {
          enabled = true;
          cpu_poll_seconds = 15.0;
          memory_poll_seconds = 20.0;
          disk_poll_seconds = 120.0;
          network_poll_seconds = 30.0;
          gpu_poll_seconds = 0.0;
        };

        control_center.calendar.show_week_numbers = true;
        control_center.media.show_visualizer = false;
      };
    };
  };
}
