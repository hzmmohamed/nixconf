# Waybar — the bar of the "waybar" desktop shell (composed stack: waybar +
# swaync + separate tools). Gated on preferences.desktopShell == "waybar".
#
# Layout: vertical bar on the right edge, solid background, no blur/alpha.
# Toggle visibility with Mod4+Shift+b (SIGUSR1). Status widgets that only matter
# sometimes (CPU, memory, disk, temperature, sync) stay hidden until relevant.
# No workspace indicator (navigation is by muscle memory); the middle is a quiet
# activity column — agents, nix builds, privacy — empty while idle.
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
    removableMedia = config.home-manager.users.${user}.services.udiskie.enable;
    swayosd-client = "${pkgs.swayosd}/bin/swayosd-client";
    networkManager = config.networking.networkmanager.enable;
    # network-ui feature (desktop): net-status / net-menu, when imported.
    netUi = lib.attrByPath ["preferences" "networkUi"] null config;
    netModules = networkManager && netUi != null;
    # swayidle feature (caffeine), when imported.
    idle = lib.attrByPath ["preferences" "idle"] null config;
    # battery-notify feature (alert tiers), when imported.
    alert = lib.attrByPath ["preferences" "batteryAlert"] {} config;
    terminal = lib.getExe selfpkgs.terminal;

    # Keyboard layout (preferences.keyboard). Not waybar's sway/language: it
    # shows whichever keyboard sent the last input event, and virtual
    # keyboards (wtype, KDE Connect, ...) carry no layout name, so it went
    # blank after login until the next toggle. This reads the first keyboard
    # with the full layout list, on every sway input event.
    kb = config.preferences.keyboard;
    layoutLabels = {
      us = "EN";
      ara = "ع";
    };
    layoutStatus = pkgs.writeShellApplication {
      name = "sway-layout-status";
      runtimeInputs = [pkgs.sway pkgs.jq];
      text = ''
        set +e
        emit() {
          swaymsg -t get_inputs -r 2>/dev/null | jq -c --unbuffered \
            --argjson layouts '${builtins.toJSON kb.layouts}' \
            --argjson labels '${builtins.toJSON layoutLabels}' '
            [.[] | select(.type == "keyboard" and ((.xkb_layout_names // []) | length) > 1)][0] as $k
            | if $k == null then {text: "", class: "none"}
              else ($layouts[$k.xkb_active_layout_index] // "") as $code
                | {text: ($labels[$code] // ($code | ascii_upcase)),
                   tooltip: ($k.xkb_active_layout_name // ""),
                   class: $code, alt: $code}
              end'
        }
        # Re-subscribe if sway restarts or the socket is not up yet.
        while true; do
          emit
          swaymsg -m -r -t subscribe '["input"]' 2>/dev/null | while read -r _; do emit; done
          sleep 1
        done
      '';
    };

    # Agent inbox (T3 Code): the configured client URL, else the local server.
    t3code = lib.attrByPath ["preferences" "agents" "t3code"] {} config;
    t3codeUrl =
      if t3code.url or null != null
      then t3code.url
      else "http://127.0.0.1:${toString (t3code.port or 3773)}";

    # Design tokens (modules/design-tokens.nix): one glyph family (Material
    # Design icons from the Nerd Font "Propo" variant: proportional, so glyphs
    # are centred and not clipped) at one size; values sit under their glyph
    # at caption size, only when relevant.
    d = self.design;
    glyphFont = d.type.family.glyph;
    glyphSize = d.type.size.glyph;
    px = n: "${toString n}px";
    value = s: "<span size='${px d.type.size.caption}'>${s}</span>";

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
      @define-color tint-pressed ${p.tint16};
      @define-color outline ${p.outline};
      @define-color outline-variant ${p.outlineVariant};
      @define-color inverse ${p.inverseSurface};
      @define-color on-inverse ${p.onInverseSurface};
      @define-color accent ${p.accent};
      @define-color accent-text ${p.accentText};
      @define-color focus ${p.focus};
      @define-color error ${p.error};
      @define-color on-error ${p.onError};
      @define-color warning ${p.warning};
      @define-color success ${p.success};
    '';

    # Calendar markup can't use CSS colors, so its colors live in a small
    # included config fragment (waybar `include`), switched with the mode.
    mkCalendarColors = p:
      builtins.toJSON {
        clock.calendar.format = {
          months = "<span color='${p.accentText}'><b>{}</b></span>";
          days = "<span color='${p.fg}'>{}</span>";
          weeks = "<span color='${p.fgMuted}'>W{}</span>";
          weekdays = "<span color='${p.fgMuted}'><b>{}</b></span>";
          today = "<span background='${p.selection}' color='${p.onSelection}'><b>{}</b></span>";
        };
      };

    netModule = part:
      lib.optionalAttrs netModules {
        exec = "${netUi.statusCommand} show ${part}";
        return-type = "json";
        interval = "once";
        signal = 12;
        justify = "center";
        hide-empty-text = true;
        on-click = netUi.menuCommand;
        on-click-right = "${terminal} ${pkgs.networkmanager}/bin/nmtui";
      };

    waybarSettings.mainBar = {
      layer = "top";
      position = "right";
      reload_style_on_change = true;
      include = ["${theme.stateDir}/current/waybar-calendar.json"];

      modules-left =
        ["clock" "custom/language" "custom/notification"]
        ++ lib.optional (idle != null) "custom/caffeine"
        ++ ["custom/mail" "mpris"];
      modules-center = ["custom/agents" "custom/agents-input" "custom/nix-build" "privacy" "custom/camera"];
      modules-right =
        lib.optional syncthingEnabled "custom/sync"
        ++ ["cpu" "memory" "custom/disk" "temperature"]
        ++ (
          if netModules
          then ["custom/wired" "custom/wifi" "custom/tailscale"]
          else lib.optional networkManager "network"
        )
        ++ ["wireplumber" "bluetooth"]
        ++ lib.optional removableMedia "custom/removable"
        ++ ["group/tray" "battery"];

      # Coding agents ($XDG_RUNTIME_DIR/agent-status, one file per session,
      # written by Claude Code hooks that send SIGRTMIN+10). Spinner + count
      # while working, a check for sessions done in the last 10 min; a
      # separate attention glyph (warning colour) for sessions waiting on me.
      "custom/agents" = {
        exec = "${lib.getExe selfpkgs.agent-status} busy";
        return-type = "json";
        format = "{icon}\n${value "{}"}";
        format-icons = {
          working = "󰝲";
          done = "󰄬";
        };
        escape = true; # project names in the tooltip
        justify = "center";
        hide-empty-text = true;
        signal = 10;
        interval = 30;
        on-click = "xdg-open ${t3codeUrl}";
      };
      "custom/agents-input" = {
        exec = "${lib.getExe selfpkgs.agent-status} input";
        return-type = "json";
        format = "󰍢\n${value "{}"}";
        escape = true; # project names in the tooltip
        justify = "center";
        hide-empty-text = true;
        signal = 10;
        interval = 30;
        on-click = "xdg-open ${t3codeUrl}";
      };

      # Nix daemon activity: snowflake + running build count (accent), or
      # dim while it only serves clients (substitutions, copies, evals).
      "custom/nix-build" = {
        exec = lib.getExe selfpkgs.nix-build-status;
        return-type = "json";
        format = "󰜗\n${value "{}"}";
        justify = "center";
        hide-empty-text = true;
        interval = 5;
      };

      # Mic capture / screen share (PipeWire Stream/Input nodes). Ignored:
      # monitor streams, the always-attached DeepFilter capture node and the
      # mixers' peak meters. Hidden while nothing captures.
      privacy = {
        icon-size = glyphSize;
        icon-spacing = d.space.sm;
        transition-duration = 0;
        modules = [
          {type = "screenshare";}
          {type = "audio-in";}
        ];
        ignore-monitor = true;
        ignore = [
          {
            type = "audio-in";
            name = "deep_filter_mono_input";
          }
          {
            type = "audio-in";
            name = "PulseAudio Volume Control";
          }
          {
            type = "audio-in";
            name = "pwvucontrol";
          }
        ];
      };

      # Camera opened directly through V4L2 (browsers bypass PipeWire).
      "custom/camera" = {
        exec = lib.getExe selfpkgs.camera-status;
        return-type = "json";
        format = "󰄀";
        hide-empty-text = true;
        interval = 5;
      };

      # Keyboard layout: short label (EN / ع), click cycles. Event-driven
      # (sway-layout-status above); hidden with a single layout.
      "custom/language" = {
        exec = lib.getExe layoutStatus;
        return-type = "json";
        hide-empty-text = true;
        escape = true;
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

      # Caffeine (swayidle feature): faint cup while the idle lock is armed,
      # accent cup (+ time left) while it is paused. Left: toggle. Right:
      # duration picker. Refreshed by `caffeine` via SIGRTMIN+13; 60 s for
      # the countdown.
      "custom/caffeine" = lib.optionalAttrs (idle != null) {
        exec = "${idle.caffeineCommand} waybar";
        return-type = "json";
        justify = "center";
        interval = 60;
        signal = 13;
        on-click = "${idle.caffeineCommand} toggle";
        on-click-right = "${idle.caffeineCommand} menu";
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

      # Root free space, absolute thresholds: hidden at >= 100 GiB free,
      # warning below, critical below 30 GiB (percent is noise on a big disk).
      "custom/disk" = {
        exec = "${lib.getExe selfpkgs.disk-free-status} /";
        return-type = "json";
        format = "󰋊\n${value "{}"}";
        justify = "center";
        hide-empty-text = true;
        interval = 300;
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

      # Network (network-ui): three glyphs, one shared tooltip (devices, IPs,
      # trusted/untrusted, connectivity). Event-driven: net-status-watch
      # refreshes the cache and sends SIGRTMIN+12 on NetworkManager, address,
      # route and trust changes; the modules only read it ("once" + signal).
      #   wired      LAN 󰈀 (fg; muted while untrusted) · cable link 󰌘
      #              (accent; "out"/"in" under it in a shared mode) ·
      #              connecting 󰌚 · link without connection 󰌙 (warning) ·
      #              no carrier 󰈂 (faint) · hidden without a wired NIC
      #   wifi       signal strength; warning colour behind a captive portal /
      #              limited; offline 󰤮 (warning) when nothing has a default
      #              route; hidden while disconnected but online over wire
      #   tailscale  󰖂 up (muted) · exit node in use (accent, "exit") ·
      #              stopped (faint) · needs login / daemon down (warning)
      # Left: network picker (same as "Network" in vicinae). Right: nmtui.
      "custom/wired" = netModule "wired";
      "custom/wifi" = netModule "wifi";
      "custom/tailscale" = netModule "tailscale";

      # Fallback without network-ui (builtin module): hidden on a working wired
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

      # Removable media (removable-media feature): drive glyph + count while a
      # USB stick / disk / SD card is mounted under /run/media/$USER, hidden
      # otherwise. Left: open/eject picker (vicinae). Right: media folder.
      # Refreshed by udiskie's event hook (SIGRTMIN+11); 60 s fallback.
      "custom/removable" = {
        exec = lib.getExe selfpkgs.removable-media-status;
        return-type = "json";
        format = "󰕓\n${value "{}"}";
        justify = "center";
        hide-empty-text = true;
        escape = true; # labels in the tooltip
        signal = 11;
        interval = 60;
        on-click = lib.getExe selfpkgs.removable-media-menu;
        on-click-right = "thunar /run/media/${user}";
      };

      # Tray: collapsed into a drawer behind one handle glyph (click to
      # reveal). Apps the bar already covers keep no tray icon (blueman →
      # bluetooth module, nm-applet → network module, flameshot → keybind).
      # Icons come from the icon theme (Papirus panel icons, monochrome)
      # where the app sends an icon name; same size as the glyphs.
      "group/tray" = {
        orientation = "inherit";
        drawer = {
          transition-duration = d.motion.base;
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
        spacing = d.bar.traySpacing;
      };

      # Battery: always shown, level glyph + percent. On battery the glyph
      # tracks the level (warning / error colour at the low / warning alert
      # tiers, inverted at critical); charging: bolt, accent; on AC and not
      # charging (full, charge limit): plug, faint. Thresholds follow
      # preferences.batteryAlert (battery-notify) when imported, whose
      # daemon also binds left click (silence the alarm).
      battery = {
        interval = 30;
        states = {
          warning = alert.low or 20;
          critical = alert.warning or 10;
          alarm = alert.critical or 7;
        };
        format = "{icon}\n${value "{capacity}"}";
        format-charging = "󰂄\n${value "{capacity}"}";
        format-plugged = "󰚥\n${value "{capacity}"}";
        format-full = "󰚥\n${value "{capacity}"}";
        format-not-charging = "󰚥\n${value "{capacity}"}";
        format-icons = ["󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹"];
        justify = "center";
        tooltip-format = "{capacity}% · {timeTo}";
        tooltip-format-discharging = "{capacity}% · {timeTo} · {power:0.1f} W";
        tooltip-format-charging = "Charging · {capacity}% · {timeTo}";
        tooltip-format-plugged = "On AC · {capacity}%";
        tooltip-format-full = "On AC · full";
        tooltip-format-not-charging = "On AC · {capacity}% (not charging)";
      };
    };

    waybarStyle = ''
      @import url("file://${theme.stateDir}/current/waybar.css");

      * {
        font-size: ${px glyphSize};
        font-family: "${glyphFont}";
        color: @fg;
        border: none;
        border-radius: 0;
        min-height: 0;
        box-shadow: none;
        text-shadow: none;
        transition: background-color ${toString d.motion.fast}ms ease-out;
      }

      window#waybar {
        background: @bar-bg;
        border-left: ${px d.bar.rule} solid @hairline;
      }

      tooltip {
        background: @surface;
        border: ${px d.panel.border} solid @outline-variant;
        border-radius: ${px d.panel.radius};
      }
      tooltip label {
        color: @fg;
        font-family: "${d.type.family.ui}";
        font-size: ${px d.type.size.body};
      }

      .modules-left, .modules-center, .modules-right {
        padding: ${px d.bar.edgePadding} 0;
      }

      /* One vertical rhythm (design tokens `bar`): every item is the same
         box (glyph + itemPaddingY above/below, itemMarginY between), glyphs
         centred, values in the same box underneath. */
      #clock, #custom-language, #custom-notification, #custom-mail, #mpris, #custom-sync,
      #cpu, #memory, #custom-disk, #temperature, #network, #custom-wired, #custom-wifi,
      #custom-tailscale, #wireplumber, #bluetooth,
      #custom-removable, #custom-tray-handle, #tray, #battery, #custom-agents, #custom-agents-input,
      #custom-nix-build, #privacy, #custom-camera {
        padding: ${px d.bar.itemPaddingY} 0;
        margin: ${px d.bar.itemMarginY} ${px d.bar.itemMarginX};
        border-radius: ${px d.bar.radius};
      }

      #clock {
        font-family: "${d.type.family.ui}";
        font-size: ${px (d.type.size.body + 2)};
      }
      #custom-language {
        color: @fg-muted;
        font-family: "${d.type.family.ui}";
        font-size: ${px d.type.size.body};
      }
      #custom-tray-handle { color: @fg-muted; }

      #clock:hover, #custom-language:hover, #custom-notification:hover, #custom-mail:hover,
      #mpris:hover, #custom-sync:hover, #network:hover, #custom-wired:hover,
      #custom-wifi:hover, #custom-tailscale:hover, #wireplumber:hover,
      #bluetooth:hover, #custom-removable:hover, #custom-tray-handle:hover, #battery:hover,
      #custom-agents:hover, #custom-agents-input:hover {
        background: @tint;
      }
      #clock:active, #custom-notification:active, #custom-mail:active, #mpris:active,
      #wireplumber:active, #bluetooth:active, #custom-tray-handle:active {
        background: @tint-pressed;
      }

      #custom-notification.dnd-notification,
      #custom-notification.dnd-none { color: @fg-faint; }
      #custom-notification.notification,
      #custom-mail { color: @accent; }

      #mpris.paused { color: @fg-faint; }

      #wireplumber.muted { color: @fg-faint; }
      #bluetooth.on { color: @fg-faint; }
      #bluetooth.connected { color: @accent; }
      #custom-removable { color: @accent; }

      #custom-sync.syncing { color: @accent; }
      #custom-sync.error, #custom-sync.down { color: @error; }

      #cpu.warning, #memory.warning, #custom-disk.warning, #temperature.warning { color: @warning; }
      #cpu.critical, #memory.critical, #custom-disk.critical, #temperature.critical { color: @error; }

      /* Activity column: agents working (accent) / recently done (faint) /
         waiting on me (warning); nix builds (accent) or daemon busy (muted);
         privacy (mic, screen share, camera) in the error colour. */
      #custom-agents.working { color: @accent; }
      #custom-agents.done { color: @fg-faint; }
      #custom-agents-input { color: @warning; }
      #custom-nix-build.build { color: @accent; }
      #custom-nix-build.busy { color: @fg-muted; }
      #privacy { padding: ${px d.space.sm} 0; }
      #privacy-item { color: @error; padding: ${px d.space.xs} 0; }
      #custom-camera { color: @error; }

      #network.disconnected, #network.linked { color: @warning; }

      #custom-wired.untrusted { color: @fg-muted; }
      #custom-wired.cable { color: @accent; }
      #custom-wired.connecting { color: @fg-muted; }
      #custom-wired.idle { color: @warning; }
      #custom-wired.nocarrier { color: @fg-faint; }
      #custom-wifi.limited, #custom-wifi.offline { color: @warning; }
      #custom-tailscale.up { color: @fg-muted; }
      #custom-tailscale.exit { color: @accent; }
      #custom-tailscale.stopped { color: @fg-faint; }
      #custom-tailscale.error { color: @warning; }

      #battery { color: @fg; }
      #battery.charging { color: @accent; }
      #battery.plugged, #battery.full, #battery.not-charging { color: @fg-faint; }
      #battery.discharging.warning { color: @warning; }
      #battery.discharging.critical { color: @error; }
      #battery.discharging.alarm { color: @on-error; background: @error; }

      #tray > .needs-attention { background: @tint; }

      /* Caffeine: same box as the other items; faint off, accent on. */
      #custom-caffeine {
        padding: ${px d.bar.itemPaddingY} 0;
        margin: ${px d.bar.itemMarginY} ${px d.bar.itemMarginX};
        border-radius: ${px d.bar.radius};
        color: @fg-faint;
      }
      #custom-caffeine:hover { background: @tint; }
      #custom-caffeine.on { color: @accent; }
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
