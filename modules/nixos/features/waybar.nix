{self, ...}: {
  flake.nixosModules.waybar = {
    config,
    lib,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    theme = self.theme;

    waybarConfig = builtins.toJSON {
      layer = "top";
      position = "top";
      reload_style_on_change = true;

      modules-left = ["sway/workspaces" "sway/mode"];
      modules-center = ["clock"];
      modules-right = ["cpu" "memory" "battery" "tray"];

      "sway/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "○";
        };
      };

      "sway/mode" = {
        format = "{}";
      };

      clock = {
        format = "{:%H:%M}";
        format-alt = "{:%A, %B %d, %Y}";
        tooltip-format = "<tt>{calendar}</tt>";
      };

      cpu = {
        format = " {usage}%";
        interval = 5;
      };

      memory = {
        format = " {percentage}%";
        interval = 5;
      };

      battery = {
        states = {
          good = 95;
          warning = 30;
          critical = 20;
        };
        format = "{icon} {capacity}%";
        format-icons = ["" "" "" "" ""];
        format-charging = " {capacity}%";
      };

      tray = {
        spacing = 10;
      };
    };

    waybarStyle = ''
      * {
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 13px;
      }

      window#waybar {
        background: ${theme.base00};
        color: ${theme.base05};
      }

      #workspaces button {
        padding: 0 5px;
        color: ${theme.base04};
      }

      #workspaces button.focused {
        color: ${theme.base0E};
      }

      #clock, #cpu, #memory, #battery, #tray {
        padding: 0 10px;
      }

      #battery.warning {
        color: ${theme.base09};
      }

      #battery.critical {
        color: ${theme.base08};
      }
    '';
  in {
    environment.systemPackages = [pkgs.waybar];

    preferences.autostart = [
      (pkgs.writeShellScriptBin "start-waybar" ''
        exec ${lib.getExe pkgs.waybar}
      '')
    ];

    hjem.users.${user}.files = {
      ".config/waybar/config.jsonc".text = waybarConfig;
      ".config/waybar/style.css".text = waybarStyle;
    };
  };
}
