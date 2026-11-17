# Waybar — the bar of the "waybar" desktop shell (composed stack: waybar +
# swaync + separate tools). Gated on preferences.desktopShell == "waybar".
#
# Layout: vertical bar on the right edge, solid background, no blur/alpha.
# Toggle visibility with Mod4+Shift+b (SIGUSR1). Status widgets that only matter
# sometimes (CPU, memory, disk, temperature, sync) stay hidden until relevant.
{self, ...}: {
  flake.nixosModules.waybar = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    theme = config.preferences.theme;
    swaync-client = "${pkgs.swaynotificationcenter}/bin/swaync-client";
    syncthingEnabled = config.services.syncthing.enable;
    swayosdEnabled = config.home-manager.users.${user}.services.swayosd.enable;
    swayosd-client = "${pkgs.swayosd}/bin/swayosd-client";
    networkManager = config.networking.networkmanager.enable;
    terminal = lib.getExe selfpkgs.terminal;

    # One glyph family (Material Design icons from the Nerd Font "Propo"
    # variant: proportional, so glyphs are centred and not clipped) at one
    # size; values sit under their glyph, smaller, only when relevant.
    glyphFont = "${self.fonts.monospace} Propo";
    glyphSize = 16;
    value = s: "<span size='small'>${s}</span>";

    # Signal the running waybar (main process only — never its module children).
    waybarSignal = sig: "systemctl --user kill --kill-whom=main -s ${sig} waybar.service";

    # Palette-only CSS (semantic names), included from the theme state dir.
    mkColorsCss = p: ''
      @define-color bar-bg ${p.surfaceContainerLow};
      @define-color surface ${p.surface};
      @define-color fg ${p.fg};
      @define-color fg-muted ${p.fgMuted};
      @define-color fg-faint ${p.fgFaint};
      @define-color hairline ${p.hairline};
      @define-color hairline-strong ${p.hairlineStrong};
      @define-color tint ${p.tint10};
      @define-color outline-variant ${p.outlineVariant};
      @define-color inverse ${p.inverseSurface};
      @define-color on-inverse ${p.onInverseSurface};
      @define-color accent ${p.accent};
      @define-color error ${p.error};
      @define-color warning ${p.peach};
      @define-color success ${p.green};
    '';

    # Calendar markup can't use CSS colors, so its colors live in a small
    # included config fragment (waybar `include`), switched with the mode.
    mkCalendarColors = p:
      builtins.toJSON {
        clock.calendar.format = {
          months = "<span color='${p.accent}'><b>{}</b></span>";
          days = "<span color='${p.fg}'>{}</span>";
          weeks = "<span color='${p.fgFaint}'>W{}</span>";
          weekdays = "<span color='${p.fgMuted}'><b>{}</b></span>";
          today = "<span color='${p.peach}'><b><u>{}</u></b></span>";
        };
      };

    waybarSettings.mainBar = {
      layer = "top";
      position = "right";
      reload_style_on_change = true;
      include = ["${theme.stateDir}/current/waybar-calendar.json"];

      modules-left = ["clock" "sway/language" "custom/notification" "custom/mail" "mpris"];
      modules-center = ["sway/workspaces"];
      modules-right =
        lib.optional syncthingEnabled "custom/sync"
        ++ ["cpu" "memory" "disk" "temperature"]
        ++ lib.optional networkManager "network"
        ++ ["wireplumber" "bluetooth" "group/tray" "battery"];

      # Dots drawn in CSS (the label is the shape): 1–6 always, 7–9 only
      # while occupied; the active one is a taller inverted pill.
      "sway/workspaces" = {
        # Real glyphs (CSS shapes on empty labels stretch across a vertical bar).
        format = "{icon}";
        format-icons = {
          focused = "●";
          urgent = "●";
          default = "●";
          persistent = "○";
        };
        persistent-workspaces = {"*" = [1 2 3 4 5 6];};
      };

      # Keyboard layout (preferences.keyboard): short label, click cycles.
      "sway/language" = {
        format = "{short}";
        format-en = "EN";
        format-us = "EN";
        format-ar = "ع";
        format-ara = "ع";
        hide-single-layout = true;
        tooltip-format = "{long}";
        on-click = "swaymsg input type:keyboard xkb_switch_layout next";
      };

      clock = {
        format = "<b>{0:%H}</b>\n{0:%M}";
        justify = "center";
        interval = 60;
        tooltip-format = "<big>{:%A, %d %B %Y}</big>\n\n<tt>{calendar}</tt>";
        calendar = {
          mode = "month";
          weeks-pos = "left";
          on-scroll = 1;
        };
        actions = {
          on-click-right = "mode";
          on-scroll-up = "shift_up";
          on-scroll-down = "shift_down";
          on-click-middle = "shift_reset";
        };
      };

      # Unread count + DND state from swaync (event-driven, no polling).
      "custom/notification" = {
        exec = "${swaync-client} -swb";
        return-type = "json";
        format = "{icon}";
        format-icons = {
          notification = "󰂚";
          none = "󰂜";
          dnd-notification = "󰂛";
          dnd-none = "󰂛";
          inhibited-notification = "󰂚";
          inhibited-none = "󰂜";
          dnd-inhibited-notification = "󰂛";
          dnd-inhibited-none = "󰂛";
        };
        tooltip = true;
        escape = true;
        on-click = "${swaync-client} -t -sw";
        on-click-right = "${swaync-client} -d -sw";
      };

      # Unread mail: local file read; refreshed by imapnotify / 5-min timer,
      # which nudge this module via SIGRTMIN+9.
      "custom/mail" = {
        exec = lib.getExe selfpkgs.mail-unread-status;
        return-type = "json";
        format = "󰇮\n${value "{}"}";
        justify = "center";
        hide-empty-text = true; # no unread mail = hidden
        interval = 120;
        signal = 9;
        on-click = "${pkgs.thunderbird}/bin/thunderbird";
        on-click-right = "mail-unread-refresh";
      };

      # Now playing: icon only (vertical bar); details in the tooltip.
      # Left click play/pause, right next, middle previous (waybar defaults).
      mpris = {
        format = "{status_icon}";
        status-icons = {
          playing = "󰎈";
          paused = "󰏤";
          stopped = "󰓛";
        };
        tooltip-format = "{player}: {artist} — {title}\n{album}";
        on-scroll-up = "playerctl next";
        on-scroll-down = "playerctl previous";
      };

      "custom/sync" = {
        exec = "${lib.getExe selfpkgs.sync-status}";
        return-type = "json";
        format = "󰓦\n${value "{}"}";
        justify = "center";
        # Idle (in sync) prints an empty text: hide the module entirely.
        hide-empty-text = true;
        interval = 30;
        on-click = "xdg-open http://${config.services.syncthing.guiAddress}";
      };

      # Threshold-only system warnings: empty format = hidden.
      cpu = {
        interval = 20;
        states = {
          warning = 90;
          critical = 97;
        };
        format = "";
        format-warning = "󰻠\n${value "{usage}"}";
        format-critical = "󰻠\n${value "{usage}"}";
        justify = "center";
        tooltip-format = "CPU {usage}%";
      };

      memory = {
        interval = 30;
        states = {
          warning = 80;
          critical = 92;
        };
        format = "";
        format-warning = "󰍛\n${value "{percentage}"}";
        format-critical = "󰍛\n${value "{percentage}"}";
        justify = "center";
        tooltip-format = "{used:0.1f} / {total:0.1f} GiB";
      };

      disk = {
        interval = 300;
        path = "/";
        states = {
          warning = 85;
          critical = 95;
        };
        format = "";
        format-warning = "󰋊\n${value "{percentage_used}"}";
        format-critical = "󰋊\n${value "{percentage_used}"}";
        justify = "center";
      };

      temperature = {
        interval = 30;
        warning-threshold = 80;
        critical-threshold = 90;
        format = "";
        format-warning = "󰔏\n${value "{temperatureC}°"}";
        format-critical = "󰔏\n${value "{temperatureC}°"}";
        justify = "center";
      };

      # Output volume: icon only; device + level in the tooltip.
      # Left: pick output (moves streams too). Right: mixer. Middle: mute.
      # Scroll: volume (through swayosd when it runs, so the OSD shows).
      wireplumber =
        {
          format = "{icon}";
          format-muted = "󰝟";
          format-icons = ["󰕿" "󰖀" "󰕾"];
          tooltip-format = "{node_name}\n{volume}%";
          max-volume = 100;
          scroll-step = 5;
          on-click = lib.getExe selfpkgs.audio-sink-menu;
          on-click-right = lib.getExe pkgs.pwvucontrol;
          on-click-middle = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        }
        // lib.optionalAttrs swayosdEnabled {
          on-scroll-up = "${swayosd-client} --output-volume +5 --max-volume 100";
          on-scroll-down = "${swayosd-client} --output-volume -5 --max-volume 100";
        };

      # Network (replaces the nm-applet tray icon): hidden on a working wired
      # link (the normal case), Wi-Fi strength on wireless, a warning glyph
      # when offline. Left: nmtui in the terminal. Right: connection editor.
      network = {
        format = "";
        format-ethernet = "";
        format-wifi = "{icon}";
        format-linked = "󰤫";
        format-disconnected = "󰤮";
        format-disabled = "";
        format-icons = ["󰤟" "󰤢" "󰤥" "󰤨"];
        tooltip-format-wifi = "{essid} · {signalStrength}%\n{ipaddr}";
        tooltip-format-linked = "{ifname}: no IP address";
        tooltip-format-disconnected = "Offline";
        on-click = "${terminal} ${pkgs.networkmanager}/bin/nmtui";
        on-click-right = "${pkgs.networkmanagerapplet}/bin/nm-connection-editor";
      };

      # Bluetooth: dim icon when idle, highlighted while a device is connected,
      # hidden without an adapter. Left: bzmenu (via vicinae). Right: blueman.
      bluetooth = {
        format = "󰂯";
        format-off = "";
        format-disabled = "";
        format-connected = "󰂱";
        format-no-controller = "";
        tooltip-format = "{controller_alias}: {status}";
        tooltip-format-connected = "{controller_alias}\n{device_enumerate}";
        tooltip-format-enumerate-connected = "{device_alias}";
        tooltip-format-enumerate-connected-battery = "{device_alias} · {device_battery_percentage}%";
        on-click = "${lib.getExe pkgs.bzmenu} -l custom -s 2 --launcher-command \"vicinae dmenu -p '{hint}'\"";
        on-click-right = "${pkgs.blueman}/bin/blueman-manager";
      };

      # Tray: collapsed into a drawer behind one handle glyph (click to
      # reveal). Apps the bar already covers keep no tray icon (blueman →
      # bluetooth module, nm-applet → network module, flameshot → keybind).
      # Icons come from the icon theme (Papirus panel icons, monochrome)
      # where the app sends an icon name; same size as the glyphs.
      "group/tray" = {
        orientation = "inherit";
        drawer = {
          transition-duration = 170;
          children-class = "tray-child";
          transition-left-to-right = false;
          click-to-reveal = true;
        };
        modules = ["custom/tray-handle" "tray"];
      };
      "custom/tray-handle" = {
        format = "󰇙";
        tooltip-format = "Tray";
      };
      tray = {
        icon-size = glyphSize;
        spacing = 8;
      };

      # Battery: only while discharging or low — hidden on AC (butternut is
      # always plugged in; hazel when docked).
      battery = {
        interval = 60;
        states = {
          warning = 30;
          critical = 15;
        };
        format = "";
        format-warning = "{icon}\n${value "{capacity}"}";
        format-critical = "{icon}\n${value "{capacity}"}";
        format-discharging = "{icon}\n${value "{capacity}"}";
        format-charging = "";
        format-plugged = "";
        format-full = "";
        format-not-charging = "";
        format-icons = ["󰁻" "󰁼" "󰁾" "󰂀" "󰂂" "󰁹"];
        justify = "center";
        tooltip-format = "{timeTo} · {power:0.1f} W";
      };
    };

    waybarStyle = ''
      @import url("file://${theme.stateDir}/current/waybar.css");

      * {
        font-size: ${toString glyphSize}px;
        font-family: "${glyphFont}";
        color: @fg;
        border: none;
        border-radius: 0;
        min-height: 0;
        box-shadow: none;
        text-shadow: none;
      }

      window#waybar {
        background: @bar-bg;
        border-left: 1px solid @hairline;
      }

      tooltip {
        background: @surface;
        border: 1px solid @outline-variant;
        border-radius: 8px;
      }
      tooltip label {
        color: @fg;
        font-family: "${self.fonts.sansSerif}";
        font-size: ${toString self.fonts.size}px;
      }

      .modules-left, .modules-center, .modules-right {
        padding: 8px 0;
      }

      /* One vertical rhythm: every item is the same box (6px above/below,
         4px gap), glyphs centred, values in the same box underneath. */
      #clock, #language, #custom-notification, #custom-mail, #mpris, #custom-sync,
      #cpu, #memory, #disk, #temperature, #network, #wireplumber, #bluetooth,
      #custom-tray-handle, #tray, #battery {
        padding: 6px 0;
        margin: 2px 4px;
        border-radius: 6px;
      }

      #clock { font-size: ${toString (glyphSize - 2)}px; }
      #language {
        color: @fg-muted;
        font-size: ${toString (glyphSize - 4)}px;
      }
      #custom-tray-handle { color: @fg-muted; }

      #clock:hover, #language:hover, #custom-notification:hover, #custom-mail:hover,
      #mpris:hover, #custom-sync:hover, #network:hover, #wireplumber:hover,
      #bluetooth:hover, #custom-tray-handle:hover, #battery:hover {
        background: @tint;
      }

      #custom-notification.dnd-notification,
      #custom-notification.dnd-none { color: @fg-faint; }
      #custom-notification.notification,
      #custom-mail { color: @accent; }

      #mpris.paused { color: @fg-faint; }

      #wireplumber.muted { color: @fg-faint; }
      #bluetooth.on { color: @fg-faint; }
      #bluetooth.connected { color: @accent; }

      #custom-sync.syncing { color: @accent; }
      #custom-sync.error, #custom-sync.down { color: @error; }

      #cpu.warning, #memory.warning, #disk.warning, #temperature.warning { color: @warning; }
      #cpu.critical, #memory.critical, #disk.critical, #temperature.critical { color: @error; }

      /* Workspaces: glyph dots (● occupied, ○ empty persistent); the focused
         one is larger and in the accent. Sway's class is .focused. */
      #workspaces { margin: 4px 0; }
      #workspaces button {
        padding: 1px 0;
        min-height: 0;
        background: none;
        border: none;
        box-shadow: none;
        color: @fg-faint;
        font-size: 11px;
      }
      #workspaces button.persistent { color: @hairline-strong; }
      #workspaces button:hover { color: @fg-muted; background: none; }
      #workspaces button.focused { color: @accent; font-size: 15px; }
      #workspaces button.urgent { color: @error; }

      #network.disconnected, #network.linked { color: @warning; }

      #battery.warning { color: @warning; }
      #battery.critical { color: @error; }

      #tray > .needs-attention { background: @tint; }
    '';
  in {
    config = lib.mkIf (config.preferences.desktopShell == "waybar") {
      preferences.theme = {
        files."waybar.css" = mkColorsCss;
        files."waybar-calendar.json" = mkCalendarColors;
        # SIGUSR2: reload config + style in place (no restart, no flicker).
        reloadHooks.waybar = "${pkgs.systemd}/bin/systemctl --user reload waybar.service 2>/dev/null || true";
      };

      home-manager.users.${user} = {
        programs.waybar = {
          enable = true;
          systemd.enable = true;
          settings = waybarSettings;
          style = waybarStyle;
        };

        # MPRIS: track the most recently active player for playerctl/media keys.
        services.playerctld.enable = true;

        # If waybar starts before WAYLAND_DISPLAY is imported, fail and retry
        # instead of being condition-skipped (a skip is never retried).
        systemd.user.services.waybar = {
          Unit = {
            ConditionEnvironment = lib.mkForce [];
            StartLimitIntervalSec = 60;
            StartLimitBurst = 30;
          };
          Service.RestartSec = 1;
        };

        # Hide/show the bar for focus.
        wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
          "Mod4+Shift+b" = "exec ${waybarSignal "SIGUSR1"}";
        };
      };
    };
  };
}
