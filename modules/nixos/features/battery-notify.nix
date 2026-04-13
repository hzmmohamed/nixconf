{...}: {
  flake.nixosModules.battery-notify = {
    config,
    pkgs,
    ...
  }: let
    user = config.preferences.user.name;

    batteryNotify = pkgs.writeShellApplication {
      name = "battery-notify";
      runtimeInputs = [pkgs.upower pkgs.libnotify];
      text = ''
        state_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/battery-notify-last"

        battery=$(upower -e | grep -m1 battery)
        if [[ -z "$battery" ]]; then
          exit 0
        fi

        info=$(upower -i "$battery")
        pct=$(echo "$info" | grep -oP 'percentage:\s+\K[0-9]+')
        state=$(echo "$info" | grep -oP 'state:\s+\K\S+')

        # Reset state when charging
        if [[ "$state" == "charging" || "$state" == "fully-charged" ]]; then
          rm -f "$state_file"
          exit 0
        fi

        if [[ -z "$pct" ]] || (( pct > 10 )); then
          exit 0
        fi

        last=$(cat "$state_file" 2>/dev/null || echo 11)

        if (( pct < last )); then
          echo "$pct" > "$state_file"
          notify-send -u critical -i battery-caution "Battery Low" "Battery at ''${pct}%"
        fi
      '';
    };
  in {
    home-manager.users.${user} = {
      systemd.user.services.battery-notify = {
        Unit = {
          Description = "Battery low notification";
          After = ["graphical-session.target"];
          PartOf = ["graphical-session.target"];
        };
        Service = {
          ExecStart = "${batteryNotify}/bin/battery-notify";
          Type = "oneshot";
          Restart = "always";
          RestartSec = 60;
        };
        Install = {
          WantedBy = ["graphical-session.target"];
        };
      };
    };
  };
}
