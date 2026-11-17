{...}: {
  flake.nixosModules.zellij = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    pal = config.preferences.theme.palette;

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
      ".config/zellij/themes/catppuccin-latte.kdl".text = mkZellijTheme "catppuccin-latte" pal.light;
      ".config/zellij/themes/catppuccin-mocha.kdl".text = mkZellijTheme "catppuccin-mocha" pal.dark;
    };

    # config.kdl is user-owned (not managed here); point its theme at the
    # mode's variant — zellij reloads config.kdl on change.
    preferences.theme.reloadHooks.zellij = ''
      cfg="$HOME/.config/zellij/config.kdl"
      [ -f "$cfg" ] || exit 0
      if [ "$mode" = dark ]; then from=catppuccin-latte to=catppuccin-mocha; else from=catppuccin-mocha to=catppuccin-latte; fi
      ${pkgs.gnused}/bin/sed -i "s/theme \"$from\"/theme \"$to\"/" "$cfg"
    '';
  };
}
