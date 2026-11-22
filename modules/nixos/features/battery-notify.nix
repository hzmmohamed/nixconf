# Battery alerts: tiered, escalating, once per discharge
# (battery-notify/battery-alert.py has the details).
#
#   low (20 %)       notification with the time left
#   warning (10 %)   sticky notification + soft chime + phone ping (KDE Connect)
#   critical (7 %)   persistent click-through overlay (top centre) + a distinct
#                    alarm on the built-in speakers at a fixed volume, every
#                    2 min until plugged in; phone ping
#
# Plugging in clears it all at once ("Charging" + a rising chime). Clicking
# the bar's battery (waybar) silences the alarm for this discharge. The
# sounds are synthesised at build time (sox), so they are ours and distinct
# from every notification sound.
#
# Remote (the café: butternut headless in the bag, hazel's screen in front of
# me): `serve.enable` exposes this battery on the trusted networks (tailnet,
# cable); `remotes = ["butternut"]` runs a second daemon that watches it with
# the same tiers ("Butternut battery low", overlay, alarm, phone ping) and
# adds a bar item. A watched host that vanishes while on battery gets one
# "unreachable" notification.
{self, ...}: {
  flake.nixosModules.battery-notify = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    cfg = config.preferences.batteryAlert;
    host = lib.toSentenceCase config.networking.hostName;
    d = self.design;
    px = n: "${toString n}px";

    # What UPower does at percentageAction (desktop feature: upower).
    # Hibernation needs swap; without it UPower falls back to powering off.
    upower = config.services.upower;
    hibernates =
      if config.swapDevices != []
      then "hibernates"
      else "shuts down";
    shutdownVerb =
      {
        PowerOff = "shuts down";
        Hibernate = hibernates;
        HybridSleep = hibernates;
        Suspend = "suspends";
      }.${
        upower.criticalPowerAction
      } or null;
    shutdown =
      lib.optionalString (upower.enable && upower.usePercentageForPolicy && shutdownVerb != null)
      "${host} ${shutdownVerb} at ${toString upower.percentageAction}%.";
    waybarShell = config.preferences.desktopShell == "waybar";

    # Three short motifs, triangle waves (they carry on small laptop speakers):
    #   alarm    E6-C6-A5 falling, twice: urgent, unlike any notification
    #   warning  A5-E5, soft, once
    #   plugged  E5-B5 rising: relief
    sounds = pkgs.runCommand "battery-alert-sounds" {nativeBuildInputs = [pkgs.sox];} ''
      mkdir -p $out
      tone() { sox -n -r 48000 -c 1 -b 16 "$1" synth "$2" triangle "$3" fade q 0.005 "$2" 0.04 vol "$4"; }
      gap() { sox -n -r 48000 -c 1 -b 16 "$1" trim 0 "$2"; }
      tone e6.wav 0.15 1318.5 0.9; tone c6.wav 0.15 1046.5 0.9; tone a5.wav 0.24 880 0.9
      gap g1.wav 0.04; gap g2.wav 0.35
      sox e6.wav g1.wav c6.wav g1.wav a5.wav g2.wav e6.wav g1.wav c6.wav g1.wav a5.wav $out/alarm.wav
      tone sa5.wav 0.18 880 0.45; tone se5.wav 0.3 659.3 0.45
      sox sa5.wav g1.wav se5.wav $out/warning.wav
      tone pe5.wav 0.12 659.3 0.5; tone pb5.wav 0.22 987.8 0.5
      sox pe5.wav g1.wav pb5.wav $out/plugged.wav
    '';

    overlayCssPath = "${config.preferences.theme.stateDir}/current/battery-overlay.css";
    overlayScript = pkgs.writers.writePython3 "battery-overlay" {
      libraries = ps: [ps.pygobject3 ps.pycairo];
      flakeIgnore = ["E501"];
    } (builtins.readFile ./battery-notify/battery-overlay.py);
    # GTK4 + gtk4-layer-shell (loaded before libwayland-client), Cairo
    # renderer: the dictation overlay's recipe.
    overlay = pkgs.stdenv.mkDerivation {
      name = "battery-overlay";
      dontUnpack = true;
      nativeBuildInputs = [pkgs.wrapGAppsHook4 pkgs.gobject-introspection];
      buildInputs = [pkgs.gtk4 pkgs.gtk4-layer-shell];
      installPhase = "install -Dm755 ${overlayScript} $out/bin/battery-overlay";
      preFixup = ''
        gappsWrapperArgs+=(
          --set LD_PRELOAD ${pkgs.gtk4-layer-shell}/lib/libgtk4-layer-shell.so
          --set-default GSK_RENDERER cairo
        )
      '';
      meta.mainProgram = "battery-overlay";
    };

    # Palette-only stylesheet, rendered per mode into the theme state dir.
    mkOverlayCss = p: ''
      window.battery-alert {
        background: ${p.surface};
        color: ${p.fg};
        border: ${px d.border.focus} solid ${p.error};
        border-radius: ${px d.panel.radius};
        box-shadow: none;
        font-family: "${d.type.family.ui}";
        font-size: ${px d.type.size.body};
      }
      window.battery-alert .panel {
        padding: ${px d.panel.padding};
        border-spacing: ${px d.space.lg};
      }
      window.battery-alert .glyph {
        color: ${p.error};
        font-family: "${d.type.family.glyph}";
        font-size: ${px d.type.size.display};
      }
      window.battery-alert .pct {
        color: ${p.error};
        font-size: ${px d.type.size.display};
        font-weight: ${toString d.type.weight.bold};
      }
      window.battery-alert .title {
        font-size: ${px d.type.size.title};
        font-weight: ${toString d.type.weight.medium};
      }
      window.battery-alert .note { color: ${p.fgMuted}; }
    '';

    # Remote watching (the café: hazel tracks a headless butternut). The
    # watched host serves its status on serve.port (trusted networks only);
    # URLs from the hosts registry, the direct cable first.
    port = toString cfg.serve.port;
    remoteUrls = name:
      lib.optional ((self.hosts.${name}.cable or null) != null) "http://${name}-cable:${port}/battery"
      ++ ["http://${name}:${port}/battery"];
    barSignal = 15; # waybar SIGRTMIN+15: remote battery state changed
    label = lib.toSentenceCase;

    mkConfig = remote:
      pkgs.writeText "battery-alert${lib.optionalString (remote != null) "-${remote}"}.json" (builtins.toJSON ({
          inherit (cfg) low warning critical phone;
          inherit host shutdown;
          alarm_interval = cfg.alarmInterval;
          alarm_volume = cfg.alarmVolume;
          sounds = {
            alarm = "${sounds}/alarm.wav";
            warning = "${sounds}/warning.wav";
            plugged = "${sounds}/plugged.wav";
          };
          overlay = [
            (lib.getExe overlay)
            "--css"
            overlayCssPath
            "--width"
            (toString d.osd.width)
            # A remote's panel sits below this machine's, should both be up.
            "--margin"
            (toString (
              if remote == null
              then d.osd.margin
              else d.osd.margin + d.osd.width / 3
            ))
            "--mute-hint"
            (lib.optionalString waybarShell (
              if remote == null
              then "Click the battery in the bar to silence the alarm."
              else "Click ${label remote}'s battery in the bar to silence the alarm."
            ))
          ];
        }
        // lib.optionalAttrs (remote != null) {
          remote = {
            name = remote;
            label = label remote;
            urls = remoteUrls remote;
          };
          bar_signal = lib.optionalString waybarShell (toString barSignal);
        }));

    alertScript = pkgs.writers.writePython3 "battery-alert-daemon" {
      flakeIgnore = ["E501"];
    } (builtins.readFile ./battery-notify/battery-alert.py);
    batteryAlert = pkgs.writeShellApplication {
      name = "battery-alert";
      runtimeInputs = [
        pkgs.libnotify
        pkgs.pipewire # pw-play, pw-dump
        pkgs.wireplumber # wpctl
        pkgs.kdePackages.kdeconnect-kde
        pkgs.systemd # udevadm, systemctl
      ];
      text = ''exec ${alertScript} "$@"'';
    };
  in {
    options.preferences.batteryAlert = {
      low = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 20;
        description = "Percent: first, plain notification.";
      };
      warning = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 10;
        description = "Percent: sticky notification, chime, phone ping.";
      };
      critical = lib.mkOption {
        type = lib.types.ints.between 1 100;
        default = 7;
        description = "Percent: persistent overlay and the repeating alarm.";
      };
      alarmInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 120;
        description = "Seconds between alarms while critical and unplugged.";
      };
      alarmVolume = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 0.7;
        description = "Speaker volume for the alarm (unmuted for it, restored after).";
      };
      phone = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ping KDE Connect devices at the warning and critical tiers.";
      };
      serve = {
        enable = lib.mkEnableOption "serving this battery's status to remote watchers (trusted networks)";
        port = lib.mkOption {
          type = lib.types.port;
          default = 7655;
          description = "TCP port of the status endpoint (the same on every host).";
        };
      };
      remotes = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["butternut"];
        description = ''
          Hosts (hosts registry names, with serve.enable) whose battery this
          machine watches: same alert tiers, titled with the host name, plus
          a bar item.
        '';
      };
    };

    config = lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.critical < cfg.warning && cfg.warning < cfg.low;
            message = "preferences.batteryAlert: expected critical < warning < low.";
          }
        ];

        preferences.theme.files."battery-overlay.css" = mkOverlayCss;
        environment.systemPackages = [batteryAlert];

        # One daemon for this battery (if any), one per watched remote.
        home-manager.users.${user}.systemd.user.services = lib.listToAttrs (map (remote:
          lib.nameValuePair "battery-notify${lib.optionalString (remote != null) "-${remote}"}" {
            Unit = {
              Description =
                if remote == null
                then "Low battery alerts (notification, overlay, alarm, phone)"
                else "Low battery alerts for ${label remote} (remote)";
              After = ["graphical-session.target"];
              PartOf = ["graphical-session.target"];
            };
            Service = {
              ExecStart = "${lib.getExe batteryAlert} --config ${mkConfig remote}";
              Restart = "on-failure";
              RestartSec = 5;
            };
            Install.WantedBy = ["graphical-session.target"];
          }) ([null] ++ cfg.remotes));
      }

      # Serve this battery to the watching hosts: one short-lived process per
      # request (socket activation), read-only, no state, trusted networks.
      (lib.mkIf cfg.serve.enable {
        preferences.trustedNetworks.allowedTCPPorts = [cfg.serve.port];
        systemd.sockets.battery-status = {
          description = "Battery status for remote battery-alert watchers";
          wantedBy = ["sockets.target"];
          listenStreams = [port];
          socketConfig = {
            Accept = true;
            MaxConnections = 8;
          };
        };
        systemd.services."battery-status@" = {
          description = "Battery status (one request)";
          serviceConfig = {
            ExecStart = "${lib.getExe batteryAlert} serve --config ${mkConfig null}";
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "journal";
            RuntimeMaxSec = 10;
            DynamicUser = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
          };
        };
      })

      # The bar: click a battery to silence its alarm. A watched remote gets
      # its own item under this one: a faint laptop while on AC, laptop +
      # percent on battery (tier colours), "?" if it vanished on battery,
      # hidden while unknown (not reachable since login).
      (lib.mkIf waybarShell {
        home-manager.users.${user}.programs.waybar = {
          settings.mainBar =
            {
              battery.on-click = "${lib.getExe batteryAlert} mute";
              modules-right = lib.mkAfter (map (r: "custom/battery-${r}") cfg.remotes);
            }
            // lib.listToAttrs (map (r:
              lib.nameValuePair "custom/battery-${r}" {
                exec = "${lib.getExe batteryAlert} bar --instance ${r} --label ${label r} --caption ${toString d.type.size.caption}";
                return-type = "json";
                interval = 60;
                signal = barSignal;
                hide-empty-text = true;
                justify = "center";
                on-click = "${lib.getExe batteryAlert} mute --instance ${r}";
              })
            cfg.remotes);
          style = lib.mkIf (cfg.remotes != []) (lib.mkAfter ''
            ${lib.concatMapStringsSep ", " (r: "#custom-battery-${r}") cfg.remotes} {
              padding: ${px d.bar.itemPaddingY} 0;
              margin: ${px d.bar.itemMarginY} ${px d.bar.itemMarginX};
              border-radius: ${px d.bar.radius};
              color: @fg-faint;
            }
            ${lib.concatMapStrings (r: let
                i = "#custom-battery-${r}";
              in ''
                ${i}:hover { background: @tint; }
                ${i}.discharging { color: @fg; }
                ${i}.discharging.low, ${i}.lost { color: @warning; }
                ${i}.discharging.warning { color: @error; }
                ${i}.discharging.critical { color: @on-error; background: @error; }
              '')
              cfg.remotes}
          '');
        };
      })
    ];
  };
}
