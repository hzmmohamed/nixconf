{...}: {
  flake.nixosModules.gtk = {
    pkgs,
    lib,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    lightTheme = "catppuccin-latte-lavender-standard+default";
  in {
    programs.dconf = {
      enable = lib.mkDefault true;
      profiles.user.databases = [
        {
          lockAll = false;
          settings."org/gnome/desktop/interface" = {
            gtk-theme = lightTheme;
            color-scheme = "prefer-light";
          };
        }
      ];
    };

    environment.systemPackages = [
      (pkgs.catppuccin-gtk.override {
        variant = "latte";
        accents = ["lavender"];
      })
      (pkgs.catppuccin-gtk.override {
        variant = "mocha";
        accents = ["lavender"];
      })
      pkgs.gtk3
      pkgs.gtk4
    ];

    home-manager.users.${user}.gtk = {
      enable = true;
      theme = {
        name = lightTheme;
      };
    };
  };
}
