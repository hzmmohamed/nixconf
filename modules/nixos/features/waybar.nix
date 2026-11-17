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
    home = config.users.users.${user}.home;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
    latte = self.catppuccin;
    mocha = self.catppuccinMocha;
    swaync-client = "${pkgs.swaynotificationcenter}/bin/swaync-client";
    syncthingEnabled = config.services.syncthing.enable;
    swayosdEnabled = config.home-manager.users.${user}.services.swayosd.enable;
    swayosd-client = "${pkgs.swayosd}/bin/swayosd-client";

    # Signal the running waybar (main process only — never its module children).
    waybarSignal = sig: "systemctl --user kill --kill-whom=main -s ${sig} waybar.service";

    mkColorsCss = cat: ''
      @define-color cat-text ${cat.text};
      @define-color cat-subtext0 ${cat.subtext0};
      @define-color cat-overlay0 ${cat.overlay0};
      @define-color cat-overlay1 ${cat.overlay1};
      @define-color cat-surface0 ${cat.surface0};
      @define-color cat-surface1 ${cat.surface1};
      @define-color cat-base ${cat.base};
      @define-color cat-mantle ${cat.mantle};
      @define-color cat-crust ${cat.crust};
      @define-color cat-lavender ${cat.lavender};
      @define-color cat-red ${cat.red};
      @define-color cat-peach ${cat.peach};
      @define-color cat-yellow ${cat.yellow};
      @define-color cat-green ${cat.green};
    '';

    # Calendar markup can't use CSS colors, so its colors live in a small
    # included config fragment that darkman swaps (then `systemctl reload`).
    mkCalendarColors = cat:
      builtins.toJSON {
        clock.calendar.format = {
          months = "<span color='${cat.lavender}'><b>{}</b></span>";
          days = "<span color='${cat.text}'>{}</span>";
          weeks = "<span color='${cat.overlay1}'>W{}</span>";
          weekdays = "<span color='${cat.subtext0}'><b>{}</b></span>";
          today = "<span color='${cat.peach}'><b><u>{}</u></b></span>";
        };
      };

    waybarSettings.mainBar = {
      layer = "top";
      position = "right";
      reload_style_on_change = true;
      include = ["${home}/.config/waybar/calendar-colors.json"];

      modules-left = ["clock" "custom/notification" "custom/mail" "mpris"];
      modules-center = ["sway/workspaces"];
      modules-right =
        lib.optional syncthingEnabled "custom/sync"
        ++ ["cpu" "memory" "disk" "temperature" "wireplumber" "bluetooth" "tray" "battery"];

      "sway/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "○";
          empty = "○";
        };
        persistent-workspaces = {"*" = [1 2 3 4 5 6 7 8 9];};
      };

      clock = {
        format = "{:%H\n%M}";
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
        format = "󰇮\n{}";
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
        format = "󰓦\n{}";
        interval = 30;
        on-click = "xdg-open http://${config.services.syncthing.guiAddress}";
      };

      # Threshold-only system warnings: empty format = hidden.
      cpu = {
        interval = 20;
        states = {
          warning = 75;
          critical = 90;
        };
        format = "";
        format-warning = "󰻠\n{usage}%";
        format-critical = "󰻠\n{usage}%";
      };

      memory = {
        interval = 30;
        states = {
          warning = 80;
          critical = 92;
        };
        format = "";
        format-warning = "󰍛\n{percentage}%";
        format-critical = "󰍛\n{percentage}%";
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
        format-warning = "󰋊\n{percentage_used}%";
        format-critical = "󰋊\n{percentage_used}%";
      };

      temperature = {
        interval = 30;
        warning-threshold = 80;
        critical-threshold = 90;
        format = "";
        format-warning = "\n{temperatureC}°";
        format-critical = "\n{temperatureC}°";
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

      # Bluetooth: dim icon when idle, highlighted while a device is connected,
      # hidden without an adapter. Left: bzmenu (via vicinae). Right: blueman.
      bluetooth = {
        format = "󰂯";
        format-off = "󰂲";
        format-disabled = "󰂲";
        format-connected = "󰂱";
        format-no-controller = "";
        tooltip-format = "{controller_alias}: {status}";
        tooltip-format-connected = "{controller_alias}\n{device_enumerate}";
        tooltip-format-enumerate-connected = "{device_alias}";
        tooltip-format-enumerate-connected-battery = "{device_alias} · {device_battery_percentage}%";
        on-click = "${lib.getExe pkgs.bzmenu} -l custom --launcher-command \"vicinae dmenu -p '{hint}'\"";
        on-click-right = "${pkgs.blueman}/bin/blueman-manager";
      };

      tray = {
        icon-size = 14;
        spacing = 8;
      };

      battery = {
        interval = 60;
        states = {
          warning = 30;
          critical = 15;
        };
        format = "{icon}\n{capacity}";
        format-charging = "󰂄\n{capacity}";
        format-plugged = "󰚥\n{capacity}";
        format-icons = ["󰁻" "󰁼" "󰁾" "󰂀" "󰂂" "󰁹"];
        tooltip-format = "{timeTo} · {power:0.1f} W";
      };
    };

    waybarStyle = ''
      @import url("catppuccin-colors.css");

      * {
        font-size: ${toString self.fonts.barSize}px;
        font-family: "${self.fonts.monospace}";
        color: @cat-text;
        border: none;
        border-radius: 0;
        min-height: 0;
        box-shadow: none;
        text-shadow: none;
      }

      window#waybar {
        background: @cat-mantle;
        border-left: 1px solid @cat-surface0;
      }

      tooltip {
        background: @cat-base;
        border: 1px solid @cat-surface1;
        border-radius: 6px;
      }
      tooltip label { color: @cat-text; }

      .modules-left, .modules-center, .modules-right {
        padding: 6px 0;
      }

      #clock, #custom-notification, #custom-mail, #mpris, #custom-sync,
      #cpu, #memory, #disk, #temperature, #wireplumber, #bluetooth, #tray, #battery {
        padding: 4px 6px;
        margin: 1px 4px;
        border-radius: 6px;
      }

      #clock {
        font-size: ${toString (self.fonts.barSize + 3)}px;
        font-weight: bold;
        padding: 6px 6px;
      }

      #clock:hover, #custom-notification:hover, #custom-mail:hover,
      #mpris:hover, #custom-sync:hover, #wireplumber:hover, #bluetooth:hover,
      #battery:hover {
        background: @cat-surface0;
      }

      #custom-notification.dnd-notification,
      #custom-notification.dnd-none { color: @cat-overlay0; }
      #custom-notification.notification,
      #custom-mail { color: @cat-lavender; }

      #mpris.paused { color: @cat-overlay1; }

      #wireplumber.muted { color: @cat-overlay0; }
      #bluetooth.on, #bluetooth.off, #bluetooth.disabled { color: @cat-overlay0; }
      #bluetooth.connected { color: @cat-lavender; }

      #custom-sync.syncing { color: @cat-lavender; }
      #custom-sync.error, #custom-sync.down { color: @cat-red; }

      #cpu.warning, #memory.warning, #disk.warning, #temperature.warning { color: @cat-peach; }
      #cpu.critical, #memory.critical, #disk.critical, #temperature.critical { color: @cat-red; }

      #workspaces { margin: 0 4px; }
      #workspaces button {
        padding: 2px 0;
        background: none;
        color: @cat-overlay0;
      }
      #workspaces button:hover { background: @cat-surface0; }
      #workspaces button label { color: inherit; }
      #workspaces button.active { color: @cat-lavender; }
      #workspaces button.empty { color: @cat-surface1; }
      #workspaces button.urgent { color: @cat-red; }

      #battery.charging, #battery.plugged { color: @cat-green; }
      #battery.warning:not(.charging) { color: @cat-peach; }
      #battery.critical:not(.charging) { color: @cat-red; font-weight: bold; }

      #tray > .needs-attention { background: @cat-surface0; }
    '';

    mkThemeHook = flavor: ''
      ${pkgs.coreutils}/bin/ln -sf "$HOME/.config/waybar/catppuccin-${flavor}.css" "$HOME/.config/waybar/catppuccin-colors.css"
      ${pkgs.coreutils}/bin/ln -sf "$HOME/.config/waybar/calendar-${flavor}.json" "$HOME/.config/waybar/calendar-colors.json"
      # SIGUSR2: reload config + style in place (no restart, no flicker).
      systemctl --user reload waybar.service 2>/dev/null || true
    '';
  in {
    config = lib.mkIf (config.preferences.desktopShell == "waybar") {
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

        # Theme variants; darkman points the *-colors.* symlinks at one of them.
        home.file = {
          ".config/waybar/catppuccin-latte.css".text = mkColorsCss latte;
          ".config/waybar/catppuccin-mocha.css".text = mkColorsCss mocha;
          ".config/waybar/calendar-latte.json".text = mkCalendarColors latte;
          ".config/waybar/calendar-mocha.json".text = mkCalendarColors mocha;
        };

        # GTK aborts on a missing @import, so make sure the runtime symlinks
        # exist before waybar ever starts. Only created when absent — darkman
        # owns them afterwards.
        home.activation.waybarInitialTheme = {
          after = ["writeBoundary"];
          before = [];
          data = ''
            d="$HOME/.config/waybar"
            mkdir -p "$d"
            for pair in catppuccin-colors.css:catppuccin-latte.css calendar-colors.json:calendar-latte.json; do
              link="$d/''${pair%%:*}"; target="$d/''${pair##*:}"
              if [ ! -e "$link" ]; then
                ${pkgs.coreutils}/bin/ln -sfn "$target" "$link"
              fi
            done
          '';
        };

        services.darkman = {
          lightModeScripts.waybar-theme = mkThemeHook "latte";
          darkModeScripts.waybar-theme = mkThemeHook "mocha";
        };

        # Hide/show the bar for focus.
        wayland.windowManager.sway.config.keybindings = lib.mkOptionDefault {
          "Mod4+Shift+b" = "exec ${waybarSignal "SIGUSR1"}";
        };
      };
    };
  };
}
