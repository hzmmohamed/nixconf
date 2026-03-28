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
      modules-right = ["group/expand" "battery" "tray"];

      "sway/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "○";
          empty = "○";
        };
        persistent-workspaces = {"*" = [1 2 3 4 5 6 7 8 9];};
      };

      "sway/mode" = {
        format = "{}";
      };

      clock = {
        format = "{:%H:%M}";
        interval = 60;
        tooltip-format = "<tt>{calendar}</tt>";
        calendar = {
          mode = "year";
          mode-mon-col = 3;
          weeks-pos = "right";
          on-scroll = 1;
        };
        actions = {on-click-right = "mode";};
      };

      "custom/expand" = {
        format = "";
        tooltip = false;
      };

      "custom/endpoint" = {
        format = "|";
        tooltip = false;
      };

      "group/expand" = {
        orientation = "horizontal";
        drawer = {
          transition-duration = 600;
          click-to-reveal = true;
        };
        modules = [
          "custom/expand"
          "cpu"
          "memory"
          "temperature"
          "custom/endpoint"
        ];
      };

      cpu = {
        format = "  {usage}%";
        tooltip = true;
      };

      memory = {
        format = "  {percentage}%";
      };

      temperature = {
        critical-threshold = 80;
        format = "  {temperatureC}°C";
      };

      battery = {
        interval = 30;
        states = {
          good = 95;
          warning = 30;
          critical = 20;
        };
        format = "{icon} {capacity}%";
        format-charging = " {capacity}%";
        format-plugged = " {capacity}%";
        format-alt = "{time} {icon}";
        format-icons = ["" "" "" "" "" ""];
      };

      tray = {
        icon-size = 14;
        spacing = 10;
      };
    };

    waybarStyle = ''
      * {
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 13px;
        color: ${theme.base05};
      }

      window#waybar {
        background: transparent;
      }

      .modules-left,
      .modules-center,
      .modules-right {
        border-radius: 10px;
        background: alpha(${theme.base00}, 0.85);
        padding: 0 4px;
      }

      tooltip {
        background: ${theme.base00};
        color: ${theme.base0E};
      }

      #workspaces button {
        all: unset;
        color: alpha(${theme.base05}, 0.4);
        padding: 0 4px;
        transition: all 0.2s ease;
      }

      #workspaces button.focused {
        color: ${theme.base0E};
        text-shadow: 0px 0px 2px rgba(0, 0, 0, 0.5);
      }

      #workspaces button.empty {
        color: rgba(0, 0, 0, 0);
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, 0.2);
      }

      #clock, #battery, #cpu, #memory, #temperature, #tray {
        padding: 0 8px;
        transition: all 0.3s ease;
      }

      #battery.charging {
        color: ${theme.base0B};
      }

      #battery.warning:not(.charging) {
        color: ${theme.base09};
      }

      #battery.critical:not(.charging) {
        color: ${theme.base08};
        animation-name: blink;
        animation-duration: 0.5s;
        animation-timing-function: linear;
        animation-iteration-count: infinite;
        animation-direction: alternate;
      }

      @keyframes blink {
        to {
          color: ${theme.base00};
        }
      }

      #custom-expand {
        color: alpha(${theme.base05}, 0.2);
        text-shadow: 0px 0px 2px rgba(0, 0, 0, 0.7);
      }

      #custom-endpoint {
        color: transparent;
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, 1);
      }

      #tray menu {
        background: ${theme.base00};
        color: ${theme.base05};
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
      ".config/waybar/config".text = waybarConfig;
      ".config/waybar/style.css".text = waybarStyle;
    };
  };
}
