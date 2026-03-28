{self, ...}: {
  flake.nixosModules.mako = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    cat = self.catppuccin;
  in {
    home-manager.users.${user} = {
      home.packages = [pkgs.libnotify];

      services.mako = {
        enable = true;
        settings = {
          font = "${self.fonts.monospace} ${toString self.fonts.size}";
          background-color = cat.base;
          text-color = cat.text;
          border-color = cat.lavender;
          progress-color = "over ${cat.sapphire}";
          border-size = 2;
          border-radius = 8;
          padding = "10";
          margin = "10";
          default-timeout = 5000;
          layer = "overlay";
          anchor = "top-right";
          width = 350;
          height = 150;
          icons = true;
          max-icon-size = 48;

          "urgency=high" = {
            border-color = cat.red;
            default-timeout = 0;
          };
        };
      };
    };
  };
}
