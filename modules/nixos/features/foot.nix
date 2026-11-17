{self, ...}: {
  flake.nixosModules.foot = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    font = self.fonts.monospace;
    fontSize = self.fonts.size;

    mkFootColors = p: ''
      [colors]
      foreground=${p.noHash.fg}
      background=${p.noHash.surface}
      regular0=${p.noHash.surfaceContainerHigh}
      regular1=${p.noHash.ansiRed}
      regular2=${p.noHash.ansiGreen}
      regular3=${p.noHash.ansiYellow}
      regular4=${p.noHash.ansiBlue}
      regular5=${p.noHash.ansiMagenta}
      regular6=${p.noHash.ansiCyan}
      regular7=${p.noHash.fgDim}
      bright0=${p.noHash.surfaceContainerHighest}
      bright1=${p.noHash.ansiRed}
      bright2=${p.noHash.ansiGreen}
      bright3=${p.noHash.ansiYellow}
      bright4=${p.noHash.ansiBlue}
      bright5=${p.noHash.ansiMagenta}
      bright6=${p.noHash.ansiCyan}
      bright7=${p.noHash.fg}
    '';
  in {
    environment.systemPackages = [pkgs.foot];

    # Palette include; switched with the mode (applies to new terminals).
    preferences.theme.files."foot.ini" = mkFootColors;

    home-manager.users.${user} = {
      xdg.configFile."foot/foot.ini".text = ''
        include=${config.preferences.theme.stateDir}/current/foot.ini

        [main]
        font=${font}:size=${toString fontSize}
        pad=${toString self.design.space.md}x${toString self.design.space.sm} center

        [scrollback]
        lines=2000

        [cursor]
        blink=yes
      '';
    };
  };
}
