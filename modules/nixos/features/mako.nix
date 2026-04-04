{self, ...}: {
  flake.nixosModules.mako = {
    pkgs,
    config,
    ...
  }: let
    user = config.preferences.user.name;
    cat = self.catppuccin;

    dndToggle = pkgs.writeShellScriptBin "dnd-toggle" ''
      if ${pkgs.mako}/bin/makoctl mode | grep -q do-not-disturb; then
        ${pkgs.mako}/bin/makoctl set-mode default
      else
        ${pkgs.mako}/bin/makoctl set-mode do-not-disturb
      fi
    '';
  in {
    home-manager.users.${user} = {
      home.packages = [pkgs.libnotify dndToggle];

      services.mako = {
        enable = true;
        settings = {
          font = "${self.fonts.sansSerif} ${toString self.fonts.size}";
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

      systemd.user.services.dnd-on = {
        Unit.Description = "Enable Do Not Disturb";
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.mako}/bin/makoctl set-mode do-not-disturb";
        };
      };

      systemd.user.timers.dnd-on = {
        Unit.Description = "Enable DND at 22:00";
        Timer = {
          OnCalendar = "*-*-* 22:00:00";
          Persistent = true;
        };
        Install.WantedBy = ["timers.target"];
      };

      systemd.user.services.dnd-off = {
        Unit.Description = "Disable Do Not Disturb";
        Service = {
          Type = "oneshot";
          ExecStart = "${pkgs.mako}/bin/makoctl set-mode default";
        };
      };

      systemd.user.timers.dnd-off = {
        Unit.Description = "Disable DND at 08:00";
        Timer = {
          OnCalendar = "*-*-* 08:00:00";
          Persistent = true;
        };
        Install.WantedBy = ["timers.target"];
      };
    };
  };
}
