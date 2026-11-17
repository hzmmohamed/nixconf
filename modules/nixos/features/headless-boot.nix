# Headless / dual-mode boot for a laptop that also has to work with no screen
# (design: docs/plans/2026-11-17-network-review.md §7, "Implemented — headless
# boot"; docs/plans/2026-11-17-agentic-workspace-design.md "dual-mode boot").
#
# Everything is behind `preferences.headlessBoot.*`, all OFF by default. The
# master `enable` turns on the harmless parts (lid switch ignored, user
# lingering); each risky part has its own enable that only takes effect when
# the master is on too:
#
#   usbKeyfile    LUKS keyfile on a USB stick (systemd initrd). The password
#                 prompt ALWAYS stays as the fallback: after `timeout` seconds
#                 without the stick, or if the key is wrong, systemd-cryptsetup
#                 asks for the password (console/plymouth + password agent).
#                 Enrolling the key (cryptsetup luksAddKey) is a manual step.
#   initrdSsh     sshd in the initrd on a static cable address, to answer the
#                 LUKS prompt remotely. Host key lives outside the Nix store.
#   detectDisplay greetd only starts when an external display is connected
#                 (internal panel connectors ignored); a DRM hotplug starts it.
#   notify        "I'm up" ntfy push with tailnet/LAN IPs and power state.
#
# Requires systemd stage 1 (`boot.initrd.systemd.enable`, default on 26.05).
{self, ...}: {
  flake.nixosModules.headless-boot = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.headlessBoot;
    user = config.preferences.user.name;
    on = sub: cfg.enable && sub.enable;

    # Exit 0 = start greetd, 1 = skip it (ExecCondition: 1..254 means the unit
    # is skipped, not failed). Waits up to `settleSeconds` for the DRM drivers
    # to report connector state before deciding.
    detectDisplay = pkgs.writeShellScript "headless-detect-display" ''
      PATH=${pkgs.coreutils}/bin:$PATH
      if [ -e /run/headless-boot/force-greeter ]; then
        echo "force-greeter flag present: starting greetd"
        exit 0
      fi
      tries=$(( ${toString cfg.detectDisplay.settleSeconds} * 2 + 1 ))
      while [ "$tries" -gt 0 ]; do
        for s in /sys/class/drm/card*-*/status; do
          [ -e "$s" ] || continue
          conn=''${s%/status}
          conn=''${conn##*/}
          conn=''${conn#card*-}
          case "$conn" in
            ${lib.concatStringsSep "|" cfg.detectDisplay.ignoreConnectors}) continue ;;
          esac
          if [ "$(cat "$s")" = connected ]; then
            echo "external display $conn connected: starting greetd"
            exit 0
          fi
        done
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] && sleep 0.5
      done
      echo "no external display connected: staying headless (greetd skipped)"
      exit 1
    '';

    imUp = pkgs.writeShellApplication {
      name = "headless-im-up";
      runtimeInputs =
        [pkgs.coreutils pkgs.curl pkgs.iproute2 pkgs.gnused pkgs.gnugrep pkgs.systemd]
        ++ lib.optional config.services.tailscale.enable config.services.tailscale.package;
      text = ''
        topic=$(tr -d '[:space:]' < ${lib.escapeShellArg (toString cfg.notify.topicFile)})
        case $topic in
          https://* | http://*) url=$topic ;;
          *) url="https://ntfy.sh/$topic" ;;
        esac
        host=$(uname -n)

        # Tailscale may still be connecting right after boot: wait a bit.
        ts="no tailscale"
        if command -v tailscale >/dev/null; then
          for _ in $(seq 1 30); do
            if ip4=$(tailscale ip -4 2>/dev/null) && [ -n "$ip4" ]; then
              ts=$ip4
              break
            fi
            sleep 2
          done
        fi

        # Every global IPv4 address except the tailnet one (Wi-Fi, cable, ...).
        lan=$(ip -4 -o addr show scope global \
          | sed -n 's/^[0-9]*: \([^ ]*\) *inet \([0-9.]*\)\/.*/\1 \2/p' \
          | grep -v '^tailscale' | paste -sd ',' - || true)

        power=""
        for ps in /sys/class/power_supply/*; do
          [ -e "$ps/type" ] || continue
          case $(cat "$ps/type") in
            Mains) [ "$(cat "$ps/online" 2>/dev/null)" = 1 ] && power="$power AC" ;;
            Battery) power="$power bat $(cat "$ps/capacity" 2>/dev/null)% ($(cat "$ps/status" 2>/dev/null))" ;;
          esac
        done

        state=$(systemctl is-system-running 2>/dev/null || true)
        curl -fsS --retry 5 --retry-delay 10 --retry-all-errors \
          -H "Title: $host is up" -H "Tags: computer" \
          -d "TS $ts | LAN ''${lan:-none} |''${power:- no power info} | $state" \
          "$url" >/dev/null
      '';
    };
  in {
    options.preferences.headlessBoot = {
      enable = lib.mkEnableOption ''
        headless-capable boot: ignore the lid switch and linger the primary
        user (both harmless). Gates every sub-feature below'';

      ignoreLid = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ignore the lid switch on battery, AC and docked (keeps running lid-closed).";
      };

      linger = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start the primary user's systemd user services at boot, without a login.";
      };

      usbKeyfile = {
        enable = lib.mkEnableOption ''
          LUKS unlock with a keyfile on a USB stick, falling back to the
          password after `timeout` seconds. Enroll the key with
          `cryptsetup luksAddKey` BEFORE enabling'';
        luksDevice = lib.mkOption {
          type = lib.types.str;
          default = "crypt";
          description = "Name of the `boot.initrd.luks.devices` entry (disko's LUKS `name`).";
        };
        deviceUuid = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "1234-ABCD";
          description = "Filesystem UUID of the stick's key partition (`lsblk -o NAME,FSTYPE,UUID`).";
        };
        path = lib.mkOption {
          type = lib.types.str;
          default = "/luks.key";
          description = "Absolute path of the key file inside the stick's filesystem.";
        };
        fsType = lib.mkOption {
          type = lib.types.enum ["vfat" "ext4" "exfat"];
          default = "vfat";
          description = "Filesystem of the key partition (its module goes into the initrd).";
        };
        timeout = lib.mkOption {
          type = lib.types.ints.positive;
          default = 10;
          description = "Seconds to wait for the stick before asking for the password.";
        };
      };

      initrdSsh = {
        enable = lib.mkEnableOption ''
          SSH in the initrd on a static Ethernet address, to type the LUKS
          password remotely. Create the host key (outside the Nix store) BEFORE
          enabling, or the bootloader install fails'';
        port = lib.mkOption {
          type = lib.types.port;
          default = 2222;
          description = "initrd sshd port (distinct from the real sshd → separate known_hosts entry).";
        };
        interface = lib.mkOption {
          type = lib.types.str;
          default = "eno2";
          description = "Interface name to configure in the initrd (used when macAddress is null).";
        };
        macAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Match the initrd interface by MAC instead of name (robust against renames).";
        };
        address = lib.mkOption {
          type = lib.types.str;
          default = "10.42.0.1/24";
          description = "Static address on the cable (no gateway, no DHCP).";
        };
        kernelModules = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["e1000e"];
          description = "NIC driver(s) for the initrd (`readlink /sys/class/net/<if>/device/driver`).";
        };
        hostKey = lib.mkOption {
          type = lib.types.str;
          default = "/etc/secrets/initrd/ssh_host_ed25519_key";
          description = ''
            Path (on the running system, NOT the Nix store) of the initrd host
            key. Copied into the initrd on the unencrypted ESP at bootloader
            install, so never reuse the real host key.
          '';
        };
        authorizedKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = builtins.attrValues self.sshKeys;
          defaultText = lib.literalExpression "builtins.attrValues self.sshKeys";
          description = "Public keys allowed to log in as root in the initrd.";
        };
      };

      detectDisplay = {
        enable = lib.mkEnableOption ''
          starting greetd only when an external display is connected (and on
          DRM hotplug). Override: `touch /run/headless-boot/force-greeter`'';
        ignoreConnectors = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          default = ["eDP-*" "LVDS-*" "DSI-*"];
          description = "Shell glob patterns of connector names (without `cardN-`) that never count as a display.";
        };
        settleSeconds = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 5;
          description = "How long to wait for a connected display before skipping greetd.";
        };
      };

      notify = {
        enable = lib.mkEnableOption "an \"I'm up\" ntfy push after boot (tailnet/LAN IPs, power state)";
        topicFile = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = lib.attrByPath ["preferences" "agents" "ntfy" "topicFile"] null config;
          defaultText = lib.literalExpression "config.preferences.agents.ntfy.topicFile or null";
          description = "File holding the ntfy topic or full URL (read as root).";
        };
      };
    };

    config = lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = (on cfg.usbKeyfile || on cfg.initrdSsh) -> config.boot.initrd.systemd.enable;
            message = "preferences.headlessBoot: usbKeyfile/initrdSsh need systemd stage 1 (boot.initrd.systemd.enable).";
          }
          {
            assertion = on cfg.usbKeyfile -> cfg.usbKeyfile.deviceUuid != null;
            message = "preferences.headlessBoot.usbKeyfile.deviceUuid must be set (filesystem UUID of the key stick).";
          }
          {
            assertion = on cfg.usbKeyfile -> config.boot.initrd.luks.devices ? ${cfg.usbKeyfile.luksDevice};
            message = "preferences.headlessBoot.usbKeyfile.luksDevice does not name a boot.initrd.luks.devices entry.";
          }
          {
            assertion = on cfg.usbKeyfile -> lib.hasPrefix "/" cfg.usbKeyfile.path;
            message = "preferences.headlessBoot.usbKeyfile.path must be absolute (inside the stick).";
          }
          {
            assertion = on cfg.detectDisplay -> config.services.greetd.enable;
            message = "preferences.headlessBoot.detectDisplay needs services.greetd.";
          }
          {
            assertion = on cfg.notify -> cfg.notify.topicFile != null;
            message = "preferences.headlessBoot.notify needs notify.topicFile (or preferences.agents.ntfy.enable).";
          }
        ];
      }

      # ---- Lid + linger (harmless) ----
      (lib.mkIf cfg.ignoreLid {
        services.logind.settings.Login = {
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandleLidSwitchDocked = "ignore";
        };
      })
      # agent-host sets the same value; equal bool definitions merge fine and
      # this feature must not depend on agent-host being imported.
      (lib.mkIf cfg.linger {
        users.users.${user}.linger = true;
      })

      # ---- USB keyfile (systemd-cryptsetup "<file>:<device>" syntax) ----
      # crypttab: crypt <dev> /luks.key:UUID=XXXX discard,keyfile-timeout=10s
      # The generator mounts the stick read-only, tries the key, and on timeout
      # or a wrong key falls back to the password prompt (tries=3 default).
      (lib.mkIf (on cfg.usbKeyfile) {
        boot.initrd.luks.devices.${cfg.usbKeyfile.luksDevice} = {
          keyFile = "${cfg.usbKeyfile.path}:UUID=${toString cfg.usbKeyfile.deviceUuid}";
          keyFileTimeout = cfg.usbKeyfile.timeout;
        };
        boot.initrd.supportedFilesystems = [cfg.usbKeyfile.fsType];
        boot.initrd.availableKernelModules = ["usb_storage" "uas" "sd_mod" "xhci_pci"];
      })

      # ---- initrd SSH over the cable ----
      # Unlock: ssh -p 2222 root@10.42.0.1, then `systemd-tty-ask-password-agent`.
      (lib.mkIf (on cfg.initrdSsh) {
        boot.initrd.availableKernelModules = cfg.initrdSsh.kernelModules;
        # Only systemd.network, NOT boot.initrd.network.enable: the latter would
        # translate networking.useDHCP into DHCP on every initrd interface.
        boot.initrd.systemd.network = {
          enable = true;
          networks."10-headless-cable" = {
            matchConfig =
              if cfg.initrdSsh.macAddress != null
              then {MACAddress = cfg.initrdSsh.macAddress;}
              else {Name = cfg.initrdSsh.interface;};
            address = [cfg.initrdSsh.address];
            networkConfig = {
              ConfigureWithoutCarrier = true;
              LinkLocalAddressing = "no";
            };
            linkConfig.RequiredForOnline = "no";
          };
        };
        # Drop the initrd address at switch-root; stage 2 (NetworkManager)
        # configures the cable itself.
        boot.initrd.network.flushBeforeStage2 = true;
        boot.initrd.network.ssh = {
          enable = true;
          inherit (cfg.initrdSsh) port authorizedKeys;
          hostKeys = [cfg.initrdSsh.hostKey];
        };
      })

      # ---- Display detection → greetd or headless ----
      (lib.mkIf (on cfg.detectDisplay) {
        systemd.services.greetd.serviceConfig.ExecCondition = "${detectDisplay}";
        systemd.tmpfiles.rules = ["d /run/headless-boot 0755 root root -"];
        # A monitor plugged in later (or a slow link) starts greetd; when it is
        # already running this is a no-op, and the condition re-checks.
        services.udev.extraRules = ''
          ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{HOTPLUG}=="1", RUN+="${config.systemd.package}/bin/systemctl --no-block start greetd.service"
        '';
      })

      # ---- "I'm up" push ----
      (lib.mkIf (on cfg.notify) {
        systemd.services.headless-im-up = {
          description = "Announce that this host is up (ntfy)";
          after = ["network-online.target" "tailscaled.service"];
          wants = ["network-online.target"];
          wantedBy = ["multi-user.target"];
          # Type=exec: boot (multi-user.target) does not wait for the push.
          serviceConfig = {
            Type = "exec";
            ExecStart = lib.getExe imUp;
            Restart = "on-failure";
            RestartSec = 60;
          };
          startLimitIntervalSec = 3600;
          startLimitBurst = 5;
          restartIfChanged = false;
        };
      })
    ]);
  };
}
