{...}: {
  # "Keyboard Shortcuts" launcher entry: every Sway binding, searchable in
  # vicinae. Built from the final, merged home-manager sway config (sway.nix
  # plus whatever swaync/swayosd/swayidle add), so it can't drift from what
  # is actually bound. Read-only: picking a row just closes the list.
  flake.nixosModules.sway = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    sway = config.home-manager.users.${user}.wayland.windowManager.sway.config;

    prettyKey = key: let
      k = lib.replaceStrings ["Mod4" "Mod1" "--locked " "--no-repeat " "--to-code "] ["Super" "Alt" "" "" ""] key;
    in
      if lib.hasPrefix "--release " k
      then "${lib.removePrefix "--release " k} (release)"
      else k;
    rows = prefix: bindings:
      lib.mapAttrsToList (key: cmd: "${prefix}${prettyKey key}\t${cmd}")
      (lib.filterAttrs (_: cmd: cmd != null) bindings);
    table = pkgs.writeText "sway-shortcuts.tsv" (lib.concatLines (
      rows "" sway.keybindings
      ++ lib.concatLists (lib.mapAttrsToList (mode: rows "[${mode}] ") sway.modes)
    ));

    shortcuts = pkgs.writeShellApplication {
      name = "sway-shortcuts";
      runtimeInputs = [pkgs.gnused pkgs.coreutils pkgs.util-linux];
      text = ''
        # Store paths → program names; sort by action so related keys cluster.
        sed -E 's#/nix/store/[^/ ]+/bin/##g; s#^([^\t]*)\texec #\1\t#' ${table} \
          | sort -t "$(printf '\t')" -k2,2 -k1,1 \
          | column -t -s "$(printf '\t')" \
          | vicinae dmenu -n "Keyboard shortcuts" -p "Search keys or actions" >/dev/null || true
      '';
    };
  in {
    home-manager.users.${user} = {
      home.packages = [shortcuts];
      xdg.desktopEntries.sway-shortcuts = {
        name = "Keyboard Shortcuts";
        genericName = "Sway key bindings";
        exec = lib.getExe shortcuts;
        icon = "preferences-desktop-keyboard-shortcuts";
        categories = ["Settings" "Utility"];
      };
    };
  };
}
