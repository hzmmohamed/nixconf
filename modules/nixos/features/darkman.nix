{...}: {
  flake.nixosModules.darkman = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;

    lightGtkTheme = "catppuccin-latte-lavender-standard+default";
    darkGtkTheme = "catppuccin-mocha-lavender-standard+default";
  in {
    home-manager.users.${user}.services.darkman = {
      enable = true;
      settings = {
        usegeoclue = false;
        lat = 30.0;
        lng = 31.2;
      };

      lightModeScripts = {
        gtk-theme = ''
          ${pkgs.dconf}/bin/dconf write \
            /org/gnome/desktop/interface/color-scheme "'prefer-light'"
          ${pkgs.dconf}/bin/dconf write \
            /org/gnome/desktop/interface/gtk-theme "'${lightGtkTheme}'"
        '';

        kitty-theme = ''
          ${pkgs.kitty}/bin/kitten themes --reload-in=all "Catppuccin Latte"
        '';

        vscodium-theme = ''
          ${pkgs.gnused}/bin/sed -i \
            's/"workbench.colorTheme": ".*"/"workbench.colorTheme": "Catppuccin Latte"/g' \
            "$HOME/.config/VSCodium/User/settings.json"
        '';

        waybar-theme = ''
          ${pkgs.coreutils}/bin/ln -sf \
            "$HOME/.config/waybar/catppuccin-latte.css" \
            "$HOME/.config/waybar/catppuccin-colors.css"
          systemctl --user restart waybar || true
        '';

        wofi-theme = ''
          ${pkgs.coreutils}/bin/ln -sf \
            "$HOME/.config/wofi/style-light.css" \
            "$HOME/.config/wofi/style.css"
        '';

        zellij-theme = ''
          ${pkgs.gnused}/bin/sed -i \
            's/theme "catppuccin-mocha"/theme "catppuccin-latte"/g' \
            "$HOME/.config/zellij/config.kdl" 2>/dev/null || true
        '';
      };

      darkModeScripts = {
        gtk-theme = ''
          ${pkgs.dconf}/bin/dconf write \
            /org/gnome/desktop/interface/color-scheme "'prefer-dark'"
          ${pkgs.dconf}/bin/dconf write \
            /org/gnome/desktop/interface/gtk-theme "'${darkGtkTheme}'"
        '';

        kitty-theme = ''
          ${pkgs.kitty}/bin/kitten themes --reload-in=all "Catppuccin Mocha"
        '';

        vscodium-theme = ''
          ${pkgs.gnused}/bin/sed -i \
            's/"workbench.colorTheme": ".*"/"workbench.colorTheme": "Catppuccin Mocha"/g' \
            "$HOME/.config/VSCodium/User/settings.json"
        '';

        waybar-theme = ''
          ${pkgs.coreutils}/bin/ln -sf \
            "$HOME/.config/waybar/catppuccin-mocha.css" \
            "$HOME/.config/waybar/catppuccin-colors.css"
          systemctl --user restart waybar || true
        '';

        wofi-theme = ''
          ${pkgs.coreutils}/bin/ln -sf \
            "$HOME/.config/wofi/style-dark.css" \
            "$HOME/.config/wofi/style.css"
        '';

        zellij-theme = ''
          ${pkgs.gnused}/bin/sed -i \
            's/theme "catppuccin-latte"/theme "catppuccin-mocha"/g' \
            "$HOME/.config/zellij/config.kdl" 2>/dev/null || true
        '';
      };
    };

    environment.systemPackages = [pkgs.darkman];
  };
}
