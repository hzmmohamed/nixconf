# audio-sink-menu — pick the default audio output from a dmenu-style launcher,
# then move every playing stream onto it.
#   AUDIO_SINK_MENU_LAUNCHER  dmenu command (stdin options → selection on stdout)
#                             default: vicinae dmenu -p Output
{...}: {
  perSystem = {pkgs, ...}: {
    packages.audio-sink-menu = pkgs.writeShellApplication {
      name = "audio-sink-menu";
      runtimeInputs = [pkgs.pulseaudio pkgs.jq pkgs.coreutils];
      text = ''
        # No --no-quick-look: with it vicinae 0.23 makes every row a file drag
        # source that swallows mouse clicks (only the keyboard works).
        read -ra launcher <<<"''${AUDIO_SINK_MENU_LAUNCHER:-vicinae dmenu -p Output}"

        sinks=$(pactl -f json list sinks)
        current=$(pactl get-default-sink)

        # One line per sink; the current default is marked.
        choice=$(jq -r --arg cur "$current" \
          '.[] | (if .name == $cur then "● " else "  " end) + (.description // .name)' \
          <<<"$sinks" | "''${launcher[@]}") || exit 0
        [ -n "$choice" ] || exit 0
        choice=''${choice#● }
        choice=''${choice#  }

        name=$(jq -r --arg d "$choice" \
          'map(select((.description // .name) == $d)) | first | .name // empty' <<<"$sinks")
        [ -n "$name" ] || exit 1

        pactl set-default-sink "$name"
        pactl -f json list sink-inputs | jq -r '.[].index' | while read -r idx; do
          pactl move-sink-input "$idx" "$name" || true
        done
      '';
    };
  };
}
