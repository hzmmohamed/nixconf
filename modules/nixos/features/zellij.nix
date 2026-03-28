{self, ...}: {
  flake.nixosModules.zellij = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    latte = self.catppuccin;
    mocha = self.catppuccinMocha;

    mkZellijTheme = name: cat: ''
      themes {
        ${name} {
          bg "${cat.base}"
          fg "${cat.text}"
          red "${cat.red}"
          green "${cat.green}"
          blue "${cat.blue}"
          yellow "${cat.yellow}"
          magenta "${cat.pink}"
          orange "${cat.peach}"
          cyan "${cat.teal}"
          black "${cat.crust}"
          white "${cat.text}"
        }
      }
    '';
  in {
    environment.systemPackages = [pkgs.zellij];

    home-manager.users.${user}.home.file = {
      ".config/zellij/themes/catppuccin-latte.kdl".text = mkZellijTheme "catppuccin-latte" latte;
      ".config/zellij/themes/catppuccin-mocha.kdl".text = mkZellijTheme "catppuccin-mocha" mocha;
    };
  };
}
