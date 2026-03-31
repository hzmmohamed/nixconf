{...}: {
  flake.nixosModules.swayidle = {
    lib,
    pkgs,
    ...
  }: let
    swaylockCmd = "${lib.getExe pkgs.swaylock} -f -c 282828";
  in {
    environment.systemPackages = with pkgs; [
      swaylock
      swayidle
    ];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-swayidle" ''
        exec ${lib.getExe pkgs.swayidle} -w \
          timeout 300 '${swaylockCmd}' \
          timeout 600 'swaymsg "output * power off"' resume 'swaymsg "output * power on"' \
          before-sleep '${swaylockCmd}' \
          lock '${swaylockCmd}'
      '')
    ];
  };
}
