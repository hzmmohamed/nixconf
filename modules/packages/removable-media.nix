# Removable media helpers for the desktop (feature: removable-media).
#
#   removable-media-status  waybar-style JSON ({text,tooltip,class}): number of
#                           removable drives with a filesystem mounted under
#                           /run/media/$USER; empty text (= hidden) when none.
#   removable-media-menu    dmenu-style picker: "Open <label>" (Thunar) and
#                           "Eject <drive>" (unmount every partition, lock
#                           LUKS, power the drive off), plus "Eject all".
#     REMOVABLE_MEDIA_LAUNCHER  dmenu command (stdin options → selection on stdout)
#                               default: vicinae dmenu -p Drives
#     REMOVABLE_MEDIA_OPEN      command to open a directory (default: thunar)
#
# Only udisks mounts of the calling user are listed (/run/media/$USER/*), so
# system disks and ignored devices (UDISKS_IGNORE, e.g. a LUKS key stick)
# never show up. Ejecting uses udiskie-umount, the same code path as the tray.
{...}: {
  perSystem = {pkgs, ...}: let
    # One JSON array of drives: [{disk, name, mounts: [{dev, label, mount, size, avail}]}].
    listDrives = ''
      base="/run/media/$(id -un)/"
      lsblk -J -o NAME,PATH,TYPE,LABEL,VENDOR,MODEL,SIZE,FSAVAIL,MOUNTPOINTS 2>/dev/null \
        | jq -c --arg base "$base" '
          def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
          [ .blockdevices[]
            | select(.type == "disk")
            | . as $disk
            | [ .. | objects
                | select((.mountpoints // []) | any(. != null and startswith($base)))
                | { dev: .path,
                    mount: ((.mountpoints | map(select(. != null and startswith($base))))[0]),
                    size: (.size // "?"),
                    avail: (.fsavail // "?") }
                | .label = (.mount | ltrimstr($base)) ] as $mounts
            | select($mounts | length > 0)
            | { disk: $disk.path,
                name: ([($disk.vendor // "" | trim), ($disk.model // "" | trim)]
                       | map(select(. != "")) | join(" ")),
                mounts: $mounts } ]'
    '';
  in {
    packages.removable-media-status = pkgs.writeShellApplication {
      name = "removable-media-status";
      runtimeInputs = [pkgs.util-linux pkgs.jq pkgs.coreutils];
      text = ''
        drives=$(${listDrives}) || drives='[]'
        jq -c '
          if length == 0 then
            {text: "", tooltip: "No removable media", class: "none", alt: "none"}
          else
            { text: (length | tostring),
              tooltip: ( [ .[] | .mounts[] | "\(.label) · \(.avail) free of \(.size)" ]
                         + ["", "Click: open or eject · Right: media folder"]
                         | join("\n") ),
              class: "mounted", alt: "mounted" }
          end' <<<"$drives"
      '';
    };

    packages.removable-media-menu = pkgs.writeShellApplication {
      name = "removable-media-menu";
      runtimeInputs = [pkgs.util-linux pkgs.jq pkgs.coreutils pkgs.gawk pkgs.udiskie pkgs.libnotify pkgs.systemd];
      text = ''
        # No --no-quick-look: with it vicinae 0.23 makes every row a file drag
        # source that swallows mouse clicks (only the keyboard works).
        read -ra launcher <<<"''${REMOVABLE_MEDIA_LAUNCHER:-vicinae dmenu -p Drives}"
        read -ra opener <<<"''${REMOVABLE_MEDIA_OPEN:-thunar}"

        drives=$(${listDrives}) || drives='[]'
        if [ "$(jq length <<<"$drives")" = 0 ]; then
          notify-send -a "Removable media" -i drive-removable-media "No removable media" "Nothing is mounted."
          exit 0
        fi

        # "<menu line>\t<action>\t<argument>", one per entry.
        entries=$(jq -r '
          ( .[] | .mounts[] | "Open  \(.label)\topen\t\(.mount)" ),
          ( .[] | "Eject  \([.mounts[].label] | join(", "))\(if .name != "" then "  (\(.name))" else "" end)\teject\t\(.disk)" ),
          ( if length > 1 then "Eject all\teject-all\t-" else empty end )
        ' <<<"$drives")

        choice=$(cut -f1 <<<"$entries" | "''${launcher[@]}") || exit 0
        [ -n "$choice" ] || exit 0
        line=$(awk -F'\t' -v c="$choice" '$1 == c { print; exit }' <<<"$entries")
        [ -n "$line" ] || exit 1
        action=$(cut -f2 <<<"$line")
        arg=$(cut -f3 <<<"$line")

        eject() {
          # --force: every mounted partition of the drive; --lock: close LUKS;
          # --detach: power the drive off, so it is safe to pull.
          if ! err=$(udiskie-umount --force --lock --detach "$@" 2>&1); then
            notify-send -a "Removable media" -u critical -i dialog-error \
              "Could not eject" "''${err:-unknown error} — close files on the drive and retry."
          fi
          # Refresh the bar now (udiskie's event hook does too, when it runs).
          systemctl --user kill --kill-whom=main -s SIGRTMIN+11 waybar.service 2>/dev/null || true
        }

        case "$action" in
          open) setsid -f "''${opener[@]}" "$arg" >/dev/null 2>&1 ;;
          eject) eject "$arg" ;;
          eject-all) mapfile -t disks < <(jq -r '.[].disk' <<<"$drives"); eject "''${disks[@]}" ;;
        esac
      '';
    };
  };
}
