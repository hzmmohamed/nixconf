# SwayOSD — volume/brightness on-screen display for the "waybar" desktop shell.
# Gated on preferences.desktopShell == "waybar" (Noctalia draws its own OSD, so
# in "noctalia" mode the plain wpctl/brightnessctl keys from sway.nix stay).
# Hosts can import it unconditionally.
{
  flake.nixosModules.swayosd = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    client = "${pkgs.swayosd}/bin/swayosd-client";
    vol = arg: "exec ${client} --output-volume ${arg} --max-volume 100";
  in {
    config = lib.mkIf (config.preferences.desktopShell == "waybar") {
      home-manager.users.${user} = {
        services.swayosd.enable = true;

        # Same session binding as the blueman/nm applets: only run inside sway,
        # after it has imported WAYLAND_DISPLAY into the user environment.
        systemd.user.services.swayosd.Unit = {
          After = ["sway-session.target"];
          Requisite = ["sway-session.target"];
        };

        # Replace sway.nix's wpctl/brightnessctl binds with OSD-showing ones.
        # mkForce on the individual keys so the rest of the mkOptionDefault
        # keybinding set still merges.
        wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault (lib.mapAttrs (_: lib.mkForce) {
          "--locked XF86AudioRaiseVolume" = vol "+5";
          "--locked XF86AudioLowerVolume" = vol "-5";
          "--locked XF86AudioMute" = "exec ${client} --output-volume mute-toggle";
          "--locked XF86AudioMicMute" = "exec ${client} --input-volume mute-toggle";
          "XF86MonBrightnessUp" = "exec ${client} --brightness +5";
          "XF86MonBrightnessDown" = "exec ${client} --brightness -5";
          "Shift+XF86MonBrightnessUp" = "exec ${client} --brightness +1";
          "Shift+XF86MonBrightnessDown" = "exec ${client} --brightness -1";
        });
      };
    };
  };
}
