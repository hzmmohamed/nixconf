# window-switch / window-kill — every Sway window in a dmenu-style launcher,
# heaviest first:  <app_id or class> · <title> · ws <n> · <memory>
# Memory = summed RSS of the window's process and all its descendants
# (browser/Electron helpers, a terminal's shell and children; shared pages
# are counted once per process). window-switch focuses the selection,
# window-kill closes it.
#   WINDOW_SWITCH_LAUNCHER  dmenu command (stdin options → selection on stdout)
#                           default: vicinae dmenu -p <prompt>
{...}: {
  perSystem = {pkgs, ...}: let
    mkPicker = name: prompt: command:
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [pkgs.sway pkgs.jq pkgs.procps pkgs.gawk pkgs.coreutils];
        text = ''
          export LC_ALL=C.UTF-8
          if [ -n "''${WINDOW_SWITCH_LAUNCHER:-}" ]; then
            read -ra launcher <<<"$WINDOW_SWITCH_LAUNCHER"
          else
            # No --no-quick-look: with it vicinae 0.23 makes every row a file drag
            # source that swallows mouse clicks (only the keyboard works).
            launcher=(vicinae dmenu -p "${prompt}")
          fi

          # con_id, pid, app, title, workspace — one line per window.
          windows=$(swaymsg -t get_tree | jq -r '
            def wins: (.nodes[]?, .floating_nodes[]?) | if .pid then . else wins end;
            .. | objects | select(.type? == "workspace") | . as $ws
            | wins
            | [.id, .pid, (.app_id // .window_properties.class // "?"),
               ((.name // "") | gsub("[\t\n]"; " ")),
               (if $ws.name == "__i3_scratch" then "scratch" else $ws.name end)]
            | @tsv')
          [ -n "$windows" ] || exit 0

          # mem_kib <TAB> con_id <TAB> row, heaviest first.
          rows=$(awk '
            NR == FNR { rss[$1] = $3; kids[$2] = kids[$2] " " $1; next }
            function tree(p,   s, n, a, i) {
              if (p in memo) return memo[p]
              s = rss[p] + 0
              n = split(kids[p], a, " ")
              for (i = 1; i <= n; i++) s += tree(a[i])
              return memo[p] = s
            }
            function human(k) {
              return k >= 1048576 ? sprintf("%.1f GB", k / 1048576) : sprintf("%d MB", k / 1024)
            }
            {
              title = $4
              if (length(title) > 60) title = substr(title, 1, 59) "…"
              m = tree($2)
              printf "%d\t%s\t%s · %s · ws %s · %s\n", m, $1, $3, title, $5, human(m)
            }
          ' FS=' ' <(ps -eo pid=,ppid=,rss=) FS='\t' <(printf '%s\n' "$windows") | sort -t "$(printf '\t')" -k1,1nr)

          choice=$(cut -f3- <<<"$rows" | "''${launcher[@]}") || exit 0
          [ -n "$choice" ] || exit 0
          id=$(CHOICE="$choice" awk -F'\t' '$3 == ENVIRON["CHOICE"] { print $2; exit }' <<<"$rows")
          [ -n "$id" ] || exit 1
          swaymsg "[con_id=$id] ${command}" >/dev/null
        '';
      };
  in {
    packages.window-switch = mkPicker "window-switch" "Windows" "focus";
    packages.window-kill = mkPicker "window-kill" "Close window" "kill";
  };
}
