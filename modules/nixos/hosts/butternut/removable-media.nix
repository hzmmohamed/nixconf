# butternut: removable media exceptions (feature: features/removable-media.nix).
#
# The LUKS boot-unlock key stick (headless.nix, `usbKeyfile`: vfat, label
# BNKEY, key file /butternut.key) must never be automounted, listed in the
# tray or shown in Thunar. Its filesystem UUID is added automatically once
# `preferences.headlessBoot.usbKeyfile.deviceUuid` is set; the label covers it
# until then (and a re-made stick with the same label).
#
# Mount it by hand when needed (read-only):
#   udisksctl mount -b /dev/disk/by-label/BNKEY -o ro
{...}: {
  flake.nixosModules.hostButternut = {
    preferences.removableMedia.ignore.labels = ["BNKEY"];
  };
}
