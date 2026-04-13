{self, ...}: {
  flake.nixosModules.waybar = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    latte = self.catppuccin;
    mocha = self.catppuccinMocha;

    mkColorsCss = cat: ''
      @define-color cat-text ${cat.text};
      @define-color cat-base ${cat.base};
      @define-color cat-mantle ${cat.mantle};
      @define-color cat-crust ${cat.crust};
      @define-color cat-lavender ${cat.lavender};
      @define-color cat-surface0 ${cat.surface0};
      @define-color cat-overlay0 ${cat.overlay0};
    '';

    waybarSettings.mainBar = {
      layer = "top";
      position = "right";
      reload_style_on_change = true;

      modules-left = ["custom/whisper" "custom/dnd" "custom/notification" "clock" "tray"];
      modules-center = ["sway/workspaces"];
      modules-right = ["group/expand" "battery"];

      "sway/workspaces" = {
        format = "{icon}";
        format-icons = {
          active = "";
          default = "○";
          empty = "○";
        };
        persistent-workspaces = {"*" = [1 2 3 4 5 6 7 8 9];};
      };

      "custom/notification" = {
        tooltip = false;
        format = "";
        escape = true;
      };

      "custom/dnd" = {
        exec = "makoctl mode 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q do-not-disturb && echo '{\"text\": \"󰂛\", \"class\": \"active\"}' || echo '{\"text\": \"󰂚\", \"class\": \"inactive\"}'";
        return-type = "json";
        interval = 2;
        on-click = "dnd-toggle";
        tooltip = false;
      };

      clock = {
        format = "{:%H:%M:%S} ";
        interval = 1;
        rotate = 270;
        tooltip-format = "<tt>{calendar}</tt>";
        calendar = {
          mode = "year";
          mode-mon-col = 3;
          weeks-pos = "right";
          on-scroll = 1;
          format = {
            months = "<span color='#ffead3'><b>{}</b></span>";
            days = "<span color='#ecc6d9'><b>{}</b></span>";
            weeks = "<span color='#99ffdd'><b>W{}</b></span>";
            weekdays = "<span color='#ffcc66'><b>{}</b></span>";
            today = "<span color='#ff6699'><b><u>{}</u></b></span>";
          };
        };
        actions = {on-click-right = "mode";};
      };

      network = {
        format-wifi = "";
        format-ethernet = "";
        format-disconnected = "";
        tooltip-format-disconnected = "Error";
        tooltip-format-wifi = "{essid} ({signalStrength}%) ";
        tooltip-format-ethernet = "{ifname} ";
      };

      bluetooth = {
        format-on = "󰂯";
        format-off = "BT-off";
        format-disabled = "󰂲";
        format-connected-battery = "{device_battery_percentage}% 󰂯";
        format-alt = "{device_alias} 󰂯";
        tooltip-format = "{controller_alias}\t{controller_address}\n\n{num_connections} connected";
        tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{num_connections} connected\n\n{device_enumerate}";
        tooltip-format-enumerate-connected = "{device_alias}\n{device_address}";
        tooltip-format-enumerate-connected-battery = "{device_alias}\n{device_address}\n{device_battery_percentage}%";
        on-click-right = "blueman-manager";
      };

      battery = {
        interval = 30;
        states = {
          good = 95;
          warning = 30;
          critical = 20;
        };
        rotate = 270;
        format = "{capacity}% {icon}";
        format-charging = "{capacity}% 󰂄";
        format-plugged = "{capacity}% 󰂄 ";
        format-alt = "{time} {icon}";
        format-icons = ["󰁻" "󰁼" "󰁾" "󰂀" "󰂂" "󰁹"];
      };

      "custom/expand" = {
        format = "^";
        tooltip = false;
      };

      "custom/endpoint" = {
        format = "|";
        tooltip = false;
      };

      "group/expand" = {
        orientation = "vertical";
        drawer = {
          transition-duration = 600;
          transition-to-left = true;
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
        format = "󰻠";
        tooltip = true;
      };

      memory = {format = "";};

      temperature = {
        critical-threshold = 80;
        format = "";
      };

      tray = {
        icon-size = 14;
        spacing = 10;
      };
    };

    waybarStyle = ''
      @import url("catppuccin-colors.css");

      * {
        color: @cat-text;
      }

      window#waybar {
        background: transparent;
      }

      * {
        font-size: ${toString self.fonts.barSize}px;
        font-family: "${self.fonts.monospace}";
      }

      .modules-left {
        border-radius: 10px;
        background: alpha(@cat-crust, .7);
        box-shadow: 0px 0px 2px rgba(0, 0, 0, .6);
        margin: 8px 8px 4px 8px;
        padding: 4px;
      }

      .modules-center {
        border-radius: 10px;
        background: alpha(@cat-crust, .7);
        box-shadow: 0px 0px 2px rgba(0, 0, 0, .6);
        margin: 4px 6px;
        padding: 4px;
      }

      .modules-right {
        border-radius: 10px;
        background: alpha(@cat-crust, .7);
        box-shadow: 0px 0px 2px rgba(0, 0, 0, .6);
        margin: 4px 8px 8px 8px;
        padding: 4px;
      }

      tooltip {
        background: @cat-base;
        color: @cat-lavender;
      }

      #clock:hover,
      #custom-notification:hover,
      #bluetooth:hover,
      #network:hover,
      #battery:hover,
      #cpu:hover,
      #memory:hover,
      #temperature:hover {
        transition: all .3s ease;
        color: @cat-text;
        background: alpha(@cat-base, .9);
      }

      #custom-notification {
        transition: all .3s ease;
        color: @cat-text;
      }

      #clock {
        color: @cat-text;
        transition: all .3s ease;
      }

      #workspaces button {
        all: unset;
        color: alpha(@cat-text, .4);
        transition: all .2s ease;
      }

      #workspaces button:hover {
        color: rgba(0, 0, 0, 0);
        border: none;
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, .5);
        transition: all 1s ease;
      }

      #workspaces button.active {
        color: @cat-lavender;
        border: none;
        text-shadow: 0px 0px 2px rgba(0, 0, 0, .5);
      }

      #workspaces button.empty {
        color: rgba(0, 0, 0, 0);
        border: none;
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, .2);
      }

      #workspaces button.empty:hover {
        color: rgba(0, 0, 0, 0);
        border: none;
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, .5);
        transition: all 1s ease;
      }

      #workspaces button.empty.active {
        color: @cat-text;
        border: none;
        text-shadow: 0px 0px 2px rgba(0, 0, 0, .5);
      }

      #bluetooth {
        transition: all .3s ease;
        color: @cat-text;
      }

      #network {
        transition: all .3s ease;
        color: @cat-text;
      }

      #battery {
        transition: all .3s ease;
        color: @cat-text;
      }

      #battery.charging {
        color: #26A65B;
      }

      #battery.warning:not(.charging) {
        color: #ffbe61;
      }

      #battery.critical:not(.charging) {
        color: #f53c3c;
        animation-name: blink;
        animation-duration: 0.5s;
        animation-timing-function: linear;
        animation-iteration-count: infinite;
        animation-direction: alternate;
      }

      @keyframes blink {
        to {
          color: @cat-base;
        }
      }

      #group-expand {
        transition: all .3s ease;
      }

      #custom-expand {
        color: alpha(@cat-text, .2);
        text-shadow: 0px 0px 2px rgba(0, 0, 0, .7);
        transition: all .3s ease;
      }

      #custom-expand:hover {
        color: rgba(255, 255, 255, .2);
        text-shadow: 0px 0px 2px rgba(255, 255, 255, .5);
      }

      #cpu, #memory, #temperature {
        transition: all .3s ease;
        color: @cat-text;
      }

      #custom-endpoint {
        color: transparent;
        text-shadow: 0px 0px 1.5px rgba(0, 0, 0, 1);
      }

      #tray {
        transition: all .3s ease;
      }

      #tray menu * {
        transition: all .3s ease;
      }

      #tray menu separator {
        transition: all .3s ease;
      }

      #custom-dnd {
        transition: all .3s ease;
        color: @cat-text;
      }

      #custom-dnd.active {
        color: @cat-overlay0;
      }
    '';
  in {
    home-manager.users.${user} = {
      programs.waybar = {
        enable = true;
        systemd.enable = true;
        settings = waybarSettings;
        style = waybarStyle;
      };

      # Catppuccin color files — darkman symlinks catppuccin-colors.css to one of these
      home.file = {
        ".config/waybar/catppuccin-latte.css".text = mkColorsCss latte;
        ".config/waybar/catppuccin-mocha.css".text = mkColorsCss mocha;
      };
    };
  };
}
