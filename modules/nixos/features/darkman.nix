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
    home-manager.users.${user} = {
      services.darkman = {
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
            ${pkgs.kitty}/bin/kitten themes --reload-in=all "Catppuccin-Latte"
          '';

          vscodium-theme = ''
            ${pkgs.gnused}/bin/sed -i \
              's/"workbench.colorTheme": ".*"/"workbench.colorTheme": "Catppuccin Latte"/g' \
              "$HOME/.config/VSCodium/User/settings.json"
          '';

          # waybar / swaync / noctalia hooks live in their own feature modules.

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

          foot-theme = ''
            ${pkgs.coreutils}/bin/ln -sf \
              "$HOME/.config/foot/catppuccin-latte.ini" \
              "$HOME/.config/foot/colors.ini"
          '';

          btop-theme = ''
            ${pkgs.gnused}/bin/sed -i \
              's/color_theme = "catppuccin_mocha"/color_theme = "catppuccin_latte"/g' \
              "$HOME/.config/btop/btop.conf" 2>/dev/null || true
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
            ${pkgs.kitty}/bin/kitten themes --reload-in=all "Catppuccin-Mocha"
          '';

          vscodium-theme = ''
            ${pkgs.gnused}/bin/sed -i \
              's/"workbench.colorTheme": ".*"/"workbench.colorTheme": "Catppuccin Mocha"/g' \
              "$HOME/.config/VSCodium/User/settings.json"
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

          foot-theme = ''
            ${pkgs.coreutils}/bin/ln -sf \
              "$HOME/.config/foot/catppuccin-mocha.ini" \
              "$HOME/.config/foot/colors.ini"
          '';

          btop-theme = ''
            ${pkgs.gnused}/bin/sed -i \
              's/color_theme = "catppuccin_latte"/color_theme = "catppuccin_mocha"/g' \
              "$HOME/.config/btop/btop.conf" 2>/dev/null || true
          '';
        };
      };

      # Create initial symlinks for light mode (darkman will manage them at runtime)
      home.activation.darkmanInitialTheme = {
        after = ["writeBoundary"];
        before = [];
        data = ''
          # (Waybar's initial symlinks: see waybar.nix)

          # Wofi: default to latte
          mkdir -p "$HOME/.config/wofi"
          [ -L "$HOME/.config/wofi/style.css" ] || \
            ${pkgs.coreutils}/bin/ln -sf \
              "$HOME/.config/wofi/style-light.css" \
              "$HOME/.config/wofi/style.css"

          # Kitty: set initial theme if not already set
          mkdir -p "$HOME/.config/kitty"
          [ -f "$HOME/.config/kitty/current-theme.conf" ] || \
            ${pkgs.kitty}/bin/kitten themes --dump-theme "Catppuccin-Latte" \
              > "$HOME/.config/kitty/current-theme.conf" 2>/dev/null || true

          # Foot: default to latte
          mkdir -p "$HOME/.config/foot"
          [ -L "$HOME/.config/foot/colors.ini" ] || \
            ${pkgs.coreutils}/bin/ln -sf \
              "$HOME/.config/foot/catppuccin-latte.ini" \
              "$HOME/.config/foot/colors.ini"
        '';
      };

      # The HM gtk module rewrites org.gnome.desktop.interface/gtk-theme to the
      # light theme on every activation. Re-apply the current darkman mode so a
      # rebuild at night doesn't leave GTK3 apps light while libadwaita is dark.
      home.activation.darkmanReapplyGtk = {
        after = ["dconfSettings"];
        before = [];
        data = ''
          bus="/run/user/$(${pkgs.coreutils}/bin/id -u)/bus"
          if [ -S "$bus" ]; then (
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
            mode="$(${pkgs.darkman}/bin/darkman get 2>/dev/null || true)"
            if [ "$mode" = dark ]; then
              run ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/color-scheme "'prefer-dark'" || true
              run ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/gtk-theme "'${darkGtkTheme}'" || true
            elif [ "$mode" = light ]; then
              run ${pkgs.dconf}/bin/dconf write /org/gnome/desktop/interface/color-scheme "'prefer-light'" || true
            fi
          )
          fi
        '';
      };
    };

    environment.systemPackages = [pkgs.darkman];
  };
}
