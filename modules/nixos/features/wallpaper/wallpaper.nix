{...}: {
  flake.nixosModules.wallpaper = {
    pkgs,
    lib,
    ...
  }: {
    environment.systemPackages = [
      pkgs.swww
      pkgs.waypaper
    ];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-swww" ''
        ${pkgs.swww}/bin/swww-daemon &
        sleep 0.5
        ${lib.getExe pkgs.swww} img ${./gruvbox-mountain-village.png} \
          --transition-type fade \
          --transition-duration 1
      '')
    ];
  };
}
