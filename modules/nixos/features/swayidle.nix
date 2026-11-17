{self, ...}: {
  flake.nixosModules.swayidle = {
    lib,
    pkgs,
    ...
  }: let
    # swaylock has no include directive, so its whole (small, appearance-only)
    # config is rendered per mode and ~/.config/swaylock/config links to the
    # current one. Plain base colour + a thin accent ring: no screenshot,
    # blur, vignette or alpha.
    mkSwaylockConfig = p: let
      c = p.noHash;
      settings = {
        font = self.fonts.sansSerif;
        font-size = 24;
        color = c.surface;

        # Clock and date overlay (swaylock-effects)
        clock = true;
        timestr = "%H:%M";
        datestr = "%A, %d %B";

        # Indicator: an always-visible thin ring
        indicator = true;
        indicator-caps-lock = true;
        indicator-radius = 110;
        indicator-thickness = 3;
        indicator-idle-visible = true;
        ignore-empty-password = true;
        show-failed-attempts = true;

        inside-color = c.surface;
        inside-clear-color = c.surface;
        inside-caps-lock-color = c.surface;
        inside-ver-color = c.surface;
        inside-wrong-color = c.surface;
        line-color = c.surface;
        line-clear-color = c.surface;
        line-caps-lock-color = c.surface;
        line-ver-color = c.surface;
        line-wrong-color = c.surface;
        separator-color = c.surface;
        layout-bg-color = c.surface;
        layout-border-color = c.surface;
        layout-text-color = c.fg;

        ring-color = c.accent;
        ring-clear-color = c.fgFaint;
        ring-caps-lock-color = c.peach;
        ring-ver-color = c.fgMuted;
        ring-wrong-color = c.error;
        key-hl-color = c.fg;
        bs-hl-color = c.error;
        caps-lock-key-hl-color = c.peach;
        caps-lock-bs-hl-color = c.error;

        text-color = c.fg;
        text-clear-color = c.fgMuted;
        text-caps-lock-color = c.peach;
        text-ver-color = c.fgMuted;
        text-wrong-color = c.error;
      };
    in
      lib.concatStrings (lib.mapAttrsToList (k: v:
        if v == true
        then "${k}\n"
        else "${k}=${toString v}\n")
      settings);

    swaylockCmd = "${lib.getExe pkgs.swaylock-effects} -f";
  in {
    environment.systemPackages = with pkgs; [
      swaylock-effects
      swayidle
    ];

    preferences.theme = {
      files."swaylock.conf" = mkSwaylockConfig;
      links.".config/swaylock/config" = "swaylock.conf";
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
