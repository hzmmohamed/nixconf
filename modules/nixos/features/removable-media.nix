# Removable media (USB sticks, external disks, SD cards, phones over MTP) on
# the desktop. Imported by the `desktop` aggregate, so only GUI hosts get it;
# headless hosts (maple, peacelily) never automount anything.
#
#   udisks2   mounts on request of the active local session only (stock polkit
#             policy: filesystem-mount / encrypted-unlock / power-off-drive are
#             `allow_active = yes`, everything else needs admin auth). Mount
#             point: /run/media/$USER/<label> (per-user, ACL-protected tmpfs).
#             Built-in mount options: always nosuid,nodev; uid/gid for
#             vfat/exfat/ntfs; ntfs3 kernel driver first. Pinned below.
#   udiskie   the only automounter (user service). LUKS → GTK passphrase
#             dialog (adw-gtk3 palette, floats as a dialog). Notifications on
#             mount (with "Browse directory" → Thunar) and unmount only. Tray
#             icon only while media is present (smart tray), with the full
#             mount/unlock/eject menu. Never opens or runs anything by itself.
#   gvfs      Thunar sidebar volumes + eject button, trash, MTP (Android),
#             sftp://, smb:// (enabled by the desktop feature).
#   waybar    `custom/removable` (waybar.nix) shows a drive glyph while media
#             is mounted; click = open/eject picker. Refreshed by udiskie's
#             event hook (SIGRTMIN+11), no polling beyond a 60 s fallback.
#
# thunar-volman is not installed: it would be a second automounter (and the
# autorun hook) next to udiskie.
#
# Hidden devices: `preferences.removableMedia.ignore.*` (plus the headless-boot
# LUKS key stick's UUID, automatically) get UDISKS_IGNORE=1 / UDISKS_AUTO=0:
# no automount, no tray entry, not in Thunar. A disk whose partition matches is
# hidden as a whole, so the bare stick can't show up as "Unpower <stick>".
# Mount such a stick by hand, read-only, when needed:
#   udisksctl mount -b /dev/disk/by-label/BNKEY -o ro    # → /run/media/$USER/BNKEY
#   udisksctl unmount -b /dev/disk/by-label/BNKEY && udisksctl power-off -b /dev/disk/by-label/BNKEY
{self, ...}: {
  flake.nixosModules.removable-media = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.preferences.removableMedia;
    user = config.preferences.user.name;
    selfpkgs = self.packages.${pkgs.stdenv.hostPlatform.system};

    # The headless-boot key stick (feature may not be imported on this host).
    keyStickUuid = lib.attrByPath ["preferences" "headlessBoot" "usbKeyfile" "deviceUuid"] null config;
    ignoredUuids = cfg.ignore.uuids ++ lib.optional (keyStickUuid != null) keyStickUuid;
    ignoredLabels = cfg.ignore.labels;
    anyIgnored = ignoredLabels != [] || ignoredUuids != [] || cfg.ignore.serials != [];

    # udev PROGRAM match for a whole disk: succeeds when one of its partitions
    # carries an ignored label/UUID. Runs only for USB/MMC disks. The kernel
    # creates partition nodes before announcing the disk, so they exist here.
    diskHasIgnoredPartition = pkgs.writeShellScript "udisks-ignore-disk" ''
      for part in "$1"?*; do
        [ -b "$part" ] || continue
        label=$(${pkgs.util-linux}/bin/blkid -p -s LABEL -o value "$part" 2>/dev/null) || label=""
        uuid=$(${pkgs.util-linux}/bin/blkid -p -s UUID -o value "$part" 2>/dev/null) || uuid=""
        ${caseExit "label" ignoredLabels}
        ${caseExit "uuid" ignoredUuids}
      done
      exit 1
    '';

    caseExit = var: values:
      lib.optionalString (values != [])
      "case \"\$${var}\" in ${lib.concatMapStringsSep "|" lib.escapeShellArg values}) exit 0 ;; esac";

    hide = ''ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"'';

    # udiskie → waybar `custom/removable` refresh (signal 11, see waybar.nix).
    eventHook = pkgs.writeShellScript "udiskie-event-hook" ''
      ${pkgs.systemd}/bin/systemctl --user kill --kill-whom=main -s SIGRTMIN+11 waybar.service 2>/dev/null || true
    '';

    # Belt and braces: udiskie also ignores these itself (it already skips
    # devices with UDISKS_IGNORE / HintIgnore).
    udiskieIgnore =
      map (l: {
        id_label = l;
        ignore = true;
      })
      ignoredLabels
      ++ map (u: {
        id_uuid = u;
        ignore = true;
      })
      ignoredUuids;
  in {
    options.preferences.removableMedia.ignore = {
      labels = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["BNKEY"];
        description = ''
          Filesystem labels (ID_FS_LABEL) that are never automounted nor shown
          in the tray or file manager. A USB/SD disk with such a partition is
          hidden as a whole.
        '';
      };
      uuids = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["1234-ABCD"];
        description = ''
          Filesystem UUIDs (ID_FS_UUID, as `lsblk -o NAME,UUID` prints them) to
          hide like `labels`. The headless-boot key stick
          (`preferences.headlessBoot.usbKeyfile.deviceUuid`) is added automatically.
        '';
      };
      serials = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Drive serials (ID_SERIAL_SHORT, `udevadm info -q property /dev/sdX`) to
          hide entirely, disk and partitions.
        '';
      };
    };

    config = {
      services.udisks2 = {
        enable = true;
        # Default /run/media/$USER: per-user, ACL-restricted, on tmpfs (no
        # stale mount points). /media (mountOnMedia) is shared between users
        # and needs boot-time cleanup — no gain on a single-user desktop.
        mountOnMedia = false;
        # Pin the safety-relevant defaults (udisks 2.11 built-ins already do
        # this; an explicit file keeps it so across upgrades).
        settings."mount_options.conf".defaults = {
          defaults = ["nosuid" "nodev"];
          ntfs_drivers = ["ntfs3" "ntfs"];
        };
      };

      # exfatprogs, ntfs-3g (fallback for volumes ntfs3 refuses), btrfs-progs:
      # fsck/label tools for udisks. Kernel drivers are built in / modules.
      boot.supportedFilesystems = {
        exfat = true;
        ntfs = true;
        btrfs = true;
      };

      services.udev.extraRules = lib.mkIf anyIgnored (lib.concatStringsSep "\n" (
        map (l: ''SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="${l}", ${hide}'') ignoredLabels
        ++ map (u: ''SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${u}", ${hide}'') ignoredUuids
        ++ map (s: ''SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="${s}", ${hide}'') cfg.ignore.serials
        ++ lib.optionals (ignoredLabels != [] || ignoredUuids != []) [
          ''SUBSYSTEM=="block", ACTION=="add|change", ENV{DEVTYPE}=="disk", ENV{ID_BUS}=="usb", PROGRAM="${diskHasIgnoredPartition} $devnode", ${hide}''
          ''SUBSYSTEM=="block", ACTION=="add|change", ENV{DEVTYPE}=="disk", KERNEL=="mmcblk[0-9]*", PROGRAM="${diskHasIgnoredPartition} $devnode", ${hide}''
        ]
        ++ [""]
      ));

      environment.systemPackages = [
        selfpkgs.removable-media-menu
        # "Drives" in the launcher: same picker as the bar module.
        (pkgs.makeDesktopItem {
          name = "removable-media";
          desktopName = "Drives";
          genericName = "Open or eject removable media";
          comment = "Open a mounted USB drive or SD card, or eject it safely";
          icon = "drive-removable-media";
          exec = lib.getExe selfpkgs.removable-media-menu;
          categories = ["System" "Utility"];
          keywords = ["usb" "eject" "unmount" "mount" "drive" "stick" "sd"];
        })
      ];

      home-manager.users.${user}.services.udiskie = {
        enable = true;
        automount = true;
        notify = true;
        tray = "auto"; # smart tray: icon only while there is something to act on
        settings = {
          program_options = {
            file_manager = "thunar";
            password_prompt = "builtin:gui";
            appindicator = true; # SNI tray (waybar / Noctalia), not XEmbed
            event_hook = "${eventHook}";
          };
          # Seconds; false = no notification. Mount + unmount only: plugging in
          # a stick says "mounted" once; unlock/lock/add/remove stay quiet.
          notifications = {
            device_mounted = 5;
            device_unmounted = 3;
            device_added = false;
            device_removed = false;
            device_unlocked = false;
            device_locked = false;
            job_failed = -1; # server default (stays until dismissed)
          };
          notification_actions = {
            device_mounted = ["browse"];
            device_added = [];
          };
          device_config = udiskieIgnore;
        };
      };
    };
  };
}
