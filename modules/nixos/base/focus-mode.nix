{
  # Focus mode (Mod+z in sway): one key that quiets the desktop and restores
  # it. Features add their own shell lines; each owns its state (under
  # $FOCUS_STATE, a per-session directory) so `leave` puts back what `enter`
  # changed and nothing else.
  flake.nixosModules.base = {lib, ...}: {
    options.preferences.focusMode = {
      enter = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Shell lines run when focus mode turns on.";
      };
      leave = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "Shell lines run when focus mode turns off.";
      };
    };
  };
}
