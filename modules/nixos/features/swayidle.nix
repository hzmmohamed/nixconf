{self, ...}: {
  flake.nixosModules.swayidle = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    mocha = self.catppuccinMocha;

    stripHash = str:
      if builtins.substring 0 1 str == "#"
      then builtins.substring 1 (builtins.stringLength str - 1) str
      else str;

    c = builtins.mapAttrs (_: v: stripHash v) mocha;

    swaylockCmd = "${lib.getExe pkgs.swaylock} -f";
  in {
    environment.systemPackages = with pkgs; [
      swaylock
      swayidle
    ];

    home-manager.users.${user}.programs.swaylock.settings = {
      color = c.base;
      font = self.fonts.monospace;
      font-size = 24;

      indicator-caps-lock = true;
      indicator-radius = 120;
      indicator-thickness = 10;
      show-failed-attempts = true;

      bs-hl-color = c.peach;
      caps-lock-bs-hl-color = c.peach;
      caps-lock-key-hl-color = c.mauve;
      inside-color = "${c.base}e0";
      inside-clear-color = "${c.base}e0";
      inside-caps-lock-color = "${c.base}e0";
      inside-ver-color = "${c.base}e0";
      inside-wrong-color = "${c.base}e0";
      key-hl-color = c.lavender;
      layout-bg-color = c.base;
      layout-border-color = c.base;
      layout-text-color = c.text;
      line-color = c.base;
      line-clear-color = c.base;
      line-caps-lock-color = c.base;
      line-ver-color = c.base;
      line-wrong-color = c.base;
      ring-color = c.surface0;
      ring-clear-color = c.peach;
      ring-caps-lock-color = c.surface0;
      ring-ver-color = c.green;
      ring-wrong-color = c.red;
      separator-color = "00000000";
      text-color = c.text;
      text-clear-color = c.peach;
      text-caps-lock-color = c.mauve;
      text-ver-color = c.text;
      text-wrong-color = c.red;
    };

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
