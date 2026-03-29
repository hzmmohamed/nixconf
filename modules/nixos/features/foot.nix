{self, ...}: {
  flake.nixosModules.foot = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    font = self.fonts.monospace;
    fontSize = self.fonts.size;

    stripHash = s: builtins.substring 1 (builtins.stringLength s - 1) s;

    mkFootColors = p: ''
      [colors]
      foreground=${stripHash p.text}
      background=${stripHash p.base}
      regular0=${stripHash p.surface1}
      regular1=${stripHash p.red}
      regular2=${stripHash p.green}
      regular3=${stripHash p.yellow}
      regular4=${stripHash p.blue}
      regular5=${stripHash p.pink}
      regular6=${stripHash p.teal}
      regular7=${stripHash p.subtext1}
      bright0=${stripHash p.surface2}
      bright1=${stripHash p.red}
      bright2=${stripHash p.green}
      bright3=${stripHash p.yellow}
      bright4=${stripHash p.blue}
      bright5=${stripHash p.pink}
      bright6=${stripHash p.teal}
      bright7=${stripHash p.subtext0}
    '';
  in {
    environment.systemPackages = [pkgs.foot];

    home-manager.users.${user} = {
      xdg.configFile."foot/foot.ini".text = ''
        include=~/.config/foot/colors.ini

        [main]
        font=${font}:size=${toString fontSize}
        pad=8x4 center

        [scrollback]
        lines=2000

        [cursor]
        blink=yes
      '';

      # Color theme files — darkman symlinks colors.ini to one of these
      xdg.configFile."foot/catppuccin-latte.ini".text = mkFootColors self.catppuccin;
      xdg.configFile."foot/catppuccin-mocha.ini".text = mkFootColors self.catppuccinMocha;
    };
  };
}
