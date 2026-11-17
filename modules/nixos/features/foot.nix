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
      foreground=${p.noHash.text}
      background=${p.noHash.base}
      regular0=${p.noHash.surface1}
      regular1=${p.noHash.red}
      regular2=${p.noHash.green}
      regular3=${p.noHash.yellow}
      regular4=${p.noHash.blue}
      regular5=${p.noHash.pink}
      regular6=${p.noHash.teal}
      regular7=${p.noHash.subtext1}
      bright0=${p.noHash.surface2}
      bright1=${p.noHash.red}
      bright2=${p.noHash.green}
      bright3=${p.noHash.yellow}
      bright4=${p.noHash.blue}
      bright5=${p.noHash.pink}
      bright6=${p.noHash.teal}
      bright7=${p.noHash.subtext0}
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
        pad=8x4 center

        [scrollback]
        lines=2000

        [cursor]
        blink=yes
      '';
    };
  };
}
