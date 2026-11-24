# SwayOSD — volume/brightness on-screen display for the "waybar" desktop shell.
# Gated on preferences.desktopShell == "waybar" (Noctalia draws its own OSD, so
# in "noctalia" mode the plain wpctl/brightnessctl keys from sway.nix stay).
# Hosts can import it unconditionally.
#
# Look: the shared panel (opaque surface, hairline border, panel radius — the
# stock stylesheet is translucent), glyph in fg, level bar in accent on a
# surface-container trough. The stylesheet is palette-only and lives in the
# theme state dir; swayosd reads it at start, so the reload hook restarts it.
{self, ...}: {
  flake.nixosModules.swayosd = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    client = "${pkgs.swayosd}/bin/swayosd-client";
    vol = arg: "exec ${client} --output-volume ${arg} --max-volume 100";
    theme = config.preferences.theme;
    d = self.design;
    px = n: "${toString n}px";

    # Resize mode readout: the focused window's size, its width as a share
    # of the workspace on the level bar (a tape measure, not a volume).
    resizeHud = pkgs.writeShellApplication {
      name = "sway-resize-hud";
      runtimeInputs = [pkgs.sway pkgs.jq];
      text = ''
        read -r w h < <(swaymsg -t get_tree -r | jq -r 'first(.. | objects
          | select(.focused == true) | "\(.rect.width) \(.rect.height)")')
        ws=$(swaymsg -t get_workspaces -r | jq -r '.[] | select(.focused) | .rect.width')
        share=$(jq -n --argjson w "$w" --argjson ws "$ws" '[$w / $ws, 1] | min')
        exec ${client} --custom-icon transform-scale --custom-progress "$share" \
          --custom-progress-text "$w × $h"
      '';
    };
    hud = cmd: "${cmd}; exec ${lib.getExe resizeHud}";

    mkStyle = p: ''
      window#osd {
        background: ${p.surface};
        border: ${px d.panel.border} solid ${p.outlineVariant};
        border-radius: ${px d.panel.radius};
        box-shadow: none;
        min-width: ${px d.osd.width};
      }
      window#osd #container { margin: ${px d.osd.margin}; }
      window#osd image, window#osd label {
        color: ${p.fg};
        font-family: "${d.type.family.ui}";
        font-size: ${px d.type.size.body};
        -gtk-icon-size: ${px d.type.size.glyph};
      }
      window#osd progressbar:disabled, window#osd image:disabled { color: ${p.fgFaint}; }
      window#osd progressbar, window#osd segmentedprogress {
        min-height: ${px d.osd.barHeight};
        border-radius: ${px d.radius.pill};
        background: transparent;
        border: none;
      }
      window#osd trough, window#osd segment {
        min-height: inherit;
        border-radius: inherit;
        border: none;
        background: ${p.surfaceContainerHigh};
      }
      window#osd progress, window#osd segment.active {
        min-height: inherit;
        border-radius: inherit;
        border: none;
        background: ${p.accent};
      }
      window#osd segment { margin-left: ${px d.space.md}; }
      window#osd segment:first-child { margin-left: 0; }
    '';
  in {
    config = lib.mkIf (config.preferences.desktopShell == "waybar") {
      preferences.theme = {
        files."swayosd.css" = mkStyle;
        reloadHooks.swayosd = "${pkgs.systemd}/bin/systemctl --user try-restart swayosd.service 2>/dev/null || true";
      };

      home-manager.users.${user} = {
        services.swayosd = {
          enable = true;
          stylePath = "${theme.stateDir}/current/swayosd.css";
        };

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
          "Mod4+r" = hud "mode \"resize\"";
        });
        # Same for the resize steps: each shows the new size.
        wayland.windowManager.sway.config.modes.resize = lib.mapAttrs (_: lib.mkForce) {
          "Left" = hud "resize shrink width 10px";
          "Down" = hud "resize grow height 10px";
          "Up" = hud "resize shrink height 10px";
          "Right" = hud "resize grow width 10px";
        };
      };
    };
  };
}
