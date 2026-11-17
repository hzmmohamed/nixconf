# dictate: push-to-talk dictation into the focused window (Sway), streamed
# segment by segment.
#
#   dictate press      key down: start a session, or stop if already latched
#   dictate release    key up: held >= tap threshold -> stop (the last
#                      segment is flushed); a short tap latches (toggle mode:
#                      press again to stop)
#   dictate toggle     start / stop (for a single binding or a script)
#   dictate cancel     stop and discard what is not typed yet (typed text stays)
#   dictate status     waybar JSON (idle / recording mm:ss / transcribing)
#   dictate file WAV [--stream] [--realtime] [--overlay]
#                      run the segment pipeline on a 16-bit WAV and print the
#                      text (--stream: each segment as it commits, with times)
#   dictate recover [--type] [--list]
#                      transcribe audio left by a crashed session and print it
#   dictate backends   show which engine a dictation would use right now
#
# The session itself (recording, VAD segmenting, transcription, typing,
# journal, overlay) is `dictate-stream record`; this script owns the key
# semantics and the bar. Every config value can be overridden from the
# environment for testing, e.g. DICTATE_SERVERS= (empty) forces the local
# engine, DICTATE_LANG=ar forces Arabic.

servers=()
read -r -a servers <<<"${DICTATE_SERVERS-$cfg_servers}"
lang_override=${DICTATE_LANG:-}
local_socket=${DICTATE_LOCAL_SOCKET:-$cfg_local_socket}
state_dir="${XDG_RUNTIME_DIR:?}/dictate"

mkdir -p "$state_dir"
exec 9>"$state_dir/lock"

lock() { flock 9; }
unlock() { flock -u 9; }
now_ms() { date +%s%3N; }
get() { cat "$state_dir/$1" 2>/dev/null || true; }
put() { printf '%s' "$2" >"$state_dir/$1"; }

refresh_bar() {
  systemctl --user kill --kill-whom=main -s "SIGRTMIN+$cfg_waybar_signal" waybar.service >/dev/null 2>&1 || true
}

notify() { # urgency timeout-ms body
  notify-send -a Dictation -i audio-input-microphone -u "$1" -t "$2" "Dictation" "$3" 2>/dev/null || true
}

session_alive() {
  local pid
  pid=$(get pid)
  [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null
}

# idle | recording | transcribing; a crashed session counts as idle.
current_state() {
  local s
  s=$(get state)
  case "$s" in
  recording | transcribing) session_alive || s=idle ;;
  *) s=idle ;;
  esac
  echo "$s"
}

current_lang() {
  if [[ -n $lang_override ]]; then
    echo "$lang_override"
    return
  fi
  local layout
  layout=$(swaymsg -t get_inputs -r 2>/dev/null | jq -r '
    [.[] | select(.type == "keyboard")] as $k
    | (([$k[] | select((.xkb_layout_names | length) > 1)] + $k)[0].xkb_active_layout_name) // ""
  ' 2>/dev/null) || layout=""
  layout_lang "$layout"
}

lang_label() { tr '[:lower:]' '[:upper:]' <<<"$1"; }

start() {
  local lang t0
  lang=$(current_lang)
  t0=$(now_ms)
  rm -f "$state_dir"/{pid,latched}
  put t0 "$t0"
  put lang "$lang"
  put state recording
  # dictate-stream starts the recorder before anything else; it stops on
  # SIGUSR1 (flushing the last segment) and cancels on SIGUSR2.
  (
    exec 9>&-
    exec setsid "$cfg_stream" record --lang "$lang" --t0 "$t0" \
      </dev/null >"$state_dir/session.log" 2>&1
  ) &
  put pid $!
  unlock
  refresh_bar
}

# Called with the lock held and state == recording.
stop() {
  put state transcribing
  kill -USR1 "$(get pid)" 2>/dev/null || put state idle
  unlock
  refresh_bar
}

cancel() {
  kill -USR2 "$(get pid)" 2>/dev/null || true
  put state idle
  unlock
  refresh_bar
  notify low 1500 "Cancelled; the text already typed stays"
}

status() {
  local t0 sec
  case "$(current_state)" in
  recording)
    t0=$(get t0)
    sec=$((($(now_ms) - ${t0:-0}) / 1000))
    printf '{"text":"󰍬\\n<span size='"'"'%spx'"'"'>%02d:%02d</span>","class":"recording","tooltip":"Dictating (%s) for %02d:%02d: release, or press again, to stop"}\n' \
      "$cfg_caption_px" $((sec / 60)) $((sec % 60)) "$(lang_label "$(get lang)")" $((sec / 60)) $((sec % 60))
    ;;
  transcribing)
    printf '{"text":"󰔟","class":"transcribing","tooltip":"Typing the last segment"}\n'
    ;;
  *) printf '{"text":""}\n' ;;
  esac
}

cmd=${1:-toggle}
case "$cmd" in
press | toggle)
  lock
  case "$(current_state)" in
  recording) stop ;;
  transcribing) ;;
  *) start ;;
  esac
  ;;
release)
  lock
  [[ $(current_state) == recording && $(get latched) != 1 ]] || exit 0
  t0=$(get t0)
  if (($(now_ms) - ${t0:-0} < cfg_tap_ms)); then
    put latched 1
    unlock
    [[ $cfg_overlay == 1 ]] || notify low 3000 "Listening ($(lang_label "$(get lang)"))… press again to stop"
  else
    stop
  fi
  ;;
cancel)
  lock
  [[ $(current_state) == recording ]] || exit 0
  cancel
  ;;
status) status ;;
file)
  [[ -r ${2:-} ]] || {
    echo "usage: dictate file WAV [--stream] [--realtime] [--overlay]" >&2
    exit 2
  }
  DICTATE_LANG=$(current_lang) exec "$cfg_stream" "$@"
  ;;
recover) exec "$cfg_stream" "$@" ;;
backends)
  lang=$(current_lang)
  for url in "${servers[@]}"; do
    if curl -fsS -o /dev/null --connect-timeout 0.6 -m 20 "$url/" 2>/dev/null; then
      echo "up    $url"
    else
      echo "down  $url"
    fi
  done
  if curl -fsS -o /dev/null -m 60 --unix-socket "$local_socket" http://local/ready 2>/dev/null; then
    echo "up    local engine ($local_socket)"
  else
    echo "down  local engine ($local_socket)"
  fi
  echo "language now: $lang"
  "$cfg_stream" recover --list
  ;;
*)
  echo "usage: dictate press|release|toggle|cancel|status|file WAV [--stream]|recover [--type]|backends" >&2
  exit 2
  ;;
esac
