{...}: {
  flake.nixosModules.cliphist = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      cliphist
      wl-clipboard
    ];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-cliphist" ''
        exec wl-paste --watch cliphist store
      '')
    ];
  };
}
