# Noctalia notifications + OSD. In this mode Noctalia is the notification
# daemon (neither mako nor swaync run). Solid, bordered cards; no blur.
{...}: {
  flake.nixosModules.noctalia = {
    config,
    lib,
    ...
  }: let
    user = config.preferences.user.name;
  in {
    config = lib.mkIf (config.preferences.desktopShell == "noctalia") {
      home-manager.users.${user}.programs.noctalia.settings = {
        notification = {
          enable_daemon = true;
          background_opacity = 1.0;
          border = true;
          border_color = "outline_variant";
          layer = "overlay";
          group_by_app = true;
          offset_x = 12;
          offset_y = 12;
        };

        osd = {
          position = "top_center";
          background_opacity = 1.0;
          border = true;
          border_color = "outline_variant";
          hide_delay_ms = 1200;
        };

        audio.enable_sounds = false;
      };
    };
  };
}
