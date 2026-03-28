{...}: {
  flake.nixosModules.gammastep = {
    lib,
    pkgs,
    ...
  }: {
    environment.systemPackages = [pkgs.gammastep];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-gammastep" ''
        exec ${lib.getExe pkgs.gammastep} -l 30.0:31.2 -t 6500:3500
      '')
    ];
  };
}
