{self, ...}: {
  flake.nixosModules.clipse = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;
    cat = self.catppuccin;
  in {
    home-manager.users.${user} = {
      home.packages = [pkgs.clipse];

      xdg.configFile = {
        "clipse/config.json".text = builtins.toJSON {
          allowDuplicates = false;
          historyFile = "clipboard_history.json";
          maxHistory = 100;
          logFile = "clipse.log";
          themeFile = "custom_theme.json";
          tempDir = "tmp_files";
          imageDisplay = {
            type = "kitty";
            scaleX = 9;
            scaleY = 9;
            heightCut = 2;
          };
        };

        "clipse/custom_theme.json".text = builtins.toJSON {
          UseCustom = true;
          TitleFore = cat.text;
          TitleBack = cat.lavender;
          TitleInfo = cat.blue;
          NormalTitle = cat.text;
          DimmedTitle = cat.overlay0;
          SelectedTitle = cat.mauve;
          NormalDesc = cat.overlay0;
          DimmedDesc = cat.overlay0;
          SelectedDesc = cat.mauve;
          StatusMsg = cat.green;
          PinIndicatorColor = cat.yellow;
          SelectedBorder = cat.lavender;
          SelectedDescBorder = cat.lavender;
          FilteredMatch = cat.text;
          FilterPrompt = cat.green;
          FilterInfo = cat.blue;
          FilterText = cat.text;
          FilterCursor = cat.yellow;
          HelpKey = cat.overlay1;
          HelpDesc = cat.overlay0;
          PageActiveDot = cat.lavender;
          PageInactiveDot = cat.overlay0;
          DividerDot = cat.lavender;
          PreviewedText = cat.text;
          PreviewBorder = cat.lavender;
        };
      };

      # Custom systemd service instead of the HM module's built-in one.
      # The HM module uses -listen which forks via nohup (unavailable in systemd PATH).
      # --listen-shell runs in the foreground, suitable for systemd Type=simple.
      # Requires sway-session.target so WAYLAND_DISPLAY is imported into the
      # user environment before clipse starts.
      systemd.user.services.clipse = {
        Unit = {
          Description = "Clipse clipboard listener";
          After = ["sway-session.target"];
          PartOf = ["graphical-session.target"];
          Requisite = ["sway-session.target"];
        };
        Service = {
          ExecStart = "${pkgs.clipse}/bin/clipse --listen-shell";
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 3;
          # clipse needs wl-copy/wl-paste in PATH for Wayland clipboard access
          Environment = "PATH=${pkgs.wl-clipboard}/bin";
        };
        Install = {
          WantedBy = ["sway-session.target"];
        };
      };
    };
  };
}
