{
  flake.nixosModules.base = {lib, ...}: {
    options.preferences.desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host has a graphical desktop. Set to true by the
        `desktop` feature; headless hosts (maple, peacelily) leave it false.
        Modules imported everywhere (e.g. `gtk` via `general`, the
        `tailscale` tray) gate their GUI bits on it.
      '';
    };
  };
}
