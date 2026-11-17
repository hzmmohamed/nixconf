# Noctalia bar: vertical, right edge, solid, no blur/shadow. Auto-hides
# (reveals at the edge / on workspace switch); Mod4+Shift+b toggles it.
# Set auto_hide = false for an always-visible bar like the waybar stack.
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
        bar.order = ["main"];
        bar.main = {
          position = "right";
          thickness = 36;
          background_opacity = 1.0;
          compositor_blur = false;
          shadow = false;
          radius = 8;
          margin_ends = 8;
          margin_edge = 6;
          padding = 10;
          widget_spacing = 6;
          capsule = false;
          reserve_space = true;
          auto_hide = true;
          show_on_workspace_switch = true;

          start = ["clock" "keyboard_layout" "notifications" "mail" "media"];
          center = ["workspaces" "agents" "agents-input" "nix-build"];
          end =
            lib.optional config.services.syncthing.enable "sync"
            ++ ["cpu-warn" "ram-warn" "temp-warn" "disk-warn" "tray" "volume" "network" "bluetooth" "battery"];
        };

        widget = {
          clock = {
            format = "{:%H:%M}";
            vertical_format = "{:%H\n%M}";
            tooltip_format = "{:%A, %d %B %Y}";
            font_weight = 700;
          };
          notifications.hide_when_no_unread = false;
          media.album_art_only = true;
          battery.peek = false;
          volume.peek = true;
          network.peek = true;
          # Keyboard layout (preferences.keyboard): short label, click cycles
          # through the compositor backend (sway xkb_switch_layout).
          keyboard_layout = {
            display = "short";
            show_icon = false;
            show_label = true;
            hide_when_single_layout = true;
          };
        };

        # Labels keyed by the XKB layout description sway reports.
        shell.keyboard_layout.custom_labels = {
          "English (US)" = "EN";
          "Arabic" = "ع";
        };
      };
    };
  };
}
