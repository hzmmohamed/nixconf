# dictate: push-to-talk dictation into the focused window (Sway). Every
# recording is a draft on disk until its text is delivered.
#
#   dictate press      key down: start a session, or stop if already latched
#   dictate release    key up: held >= tap threshold -> stop; a short tap
#                      latches (toggle mode: press again to stop)
#   dictate toggle     start / stop (for a single binding or a script)
#   dictate cancel     stop; nothing more is typed (the draft is kept)
#   dictate mode [batch|stream|toggle]
#                      the mode of the next sessions: batch types the text at
#                      the end, stream types each segment at its pause
#   dictate status     waybar JSON (idle / recording mm:ss / transcribing)
#   dictate drafts     list drafts: status, duration, first words
#   dictate recover [ID|--latest] [--type|--copy] [--all] [--fresh]
#                      transcribe what a draft has not delivered; print it,
#                      type it or copy it (no ID: every pending draft)
#   dictate discard ID delete a draft
#   dictate menu       launcher picker: drafts (copy / type / retranscribe /
#                      discard) and the mode switch
#   dictate file WAV [--stream] [--mode M] [--realtime] [--overlay]
#                      run the pipeline on a 16-bit WAV and print the text
#                      (--stream: each segment as it commits, with times)
#   dictate backends   show which engine a dictation would use right now
#
# The session itself (recording, VAD segmenting, transcription, typing,
# drafts, journal, overlay) is `dictate-stream record`; this script owns the
# key semantics, the mode switch, the picker and the bar. Every config value can be overridden from the
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

current_mode() {
  local m
  m=$(cat "$cfg_mode_file" 2>/dev/null || true)
  case "$m" in
  batch | stream) echo "$m" ;;
  *) echo "$cfg_mode" ;;
  esac
}

mode_label() {
  case "$1" in
  stream) echo "live typing at each pause" ;;
  *) echo "typed at the end" ;;
  esac
}

set_mode() {
  local m=$1
  if [[ $m == toggle ]]; then
    m="batch"
    [[ $(current_mode) == batch ]] && m="stream"
  fi
  mkdir -p "$(dirname "$cfg_mode_file")"
  printf '%s\n' "$m" >"$cfg_mode_file"
  notify low 3000 "Next dictation: $(mode_label "$m") ($m mode)"
}

start() {
  local lang t0
  lang=$(current_lang)
  t0=$(now_ms)
  mode=$(current_mode)
  rm -f "$state_dir"/{pid,latched}
  put t0 "$t0"
  put lang "$lang"
  put mode "$mode"
  put state recording
  # dictate-stream starts the recorder before anything else; it stops on
  # SIGUSR1 (flushing the last segment) and cancels on SIGUSR2.
  (
    exec 9>&-
    exec setsid "$cfg_stream" record --lang "$lang" --t0 "$t0" --mode "$mode" \
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
}

status() {
  local t0 sec class
  case "$(current_state)" in
  recording)
    t0=$(get t0)
    sec=$((($(now_ms) - ${t0:-0}) / 1000))
    class='"recording"'
    ((sec >= cfg_long_sec)) && class='"recording","long"'
    printf '{"text":"󰍬\\n<span size='"'"'%spx'"'"'>%02d:%02d</span>","class":[%s],"tooltip":"Dictating (%s, %s) for %02d:%02d: release, or press again, to stop"}\n' \
      "$cfg_caption_px" $((sec / 60)) $((sec % 60)) "$class" "$(lang_label "$(get lang)")" \
      "$(mode_label "$(get mode)")" $((sec / 60)) $((sec % 60))
    ;;
  transcribing)
    printf '{"text":"󰔟","class":"transcribing","tooltip":"Transcribing the draft"}\n'
    ;;
  *) printf '{"text":""}\n' ;;
  esac
}

# Launcher picker (vicinae dmenu, same pattern as Drives / Network): drafts,
# newest first, then the mode switch; a draft opens its actions.
menu() {
  local launcher drafts entries choice line id action err
  read -ra launcher <<<"${DICTATE_LAUNCHER:-vicinae dmenu -p Dictation --no-quick-look}"
  drafts=$("$cfg_stream" drafts --json) || drafts='[]'
  # "<menu line>\t<draft id or action>"
  entries=$(jq -r '
    def st: {pending: "Not delivered", interrupted: "Interrupted", done: "Delivered",
             cancelled: "Cancelled", recording: "Recording", transcribing: "Transcribing"}[.] // .;
    def mmss: (. | floor) as $s | "\($s / 60 | floor | tostring | if length < 2 then "0" + . else . end):\($s % 60 | tostring | if length < 2 then "0" + . else . end)";
    .[] | "\(.status | st)  ·  \(.duration | mmss)  ·  \(.id[5:10]) \(.id[11:13]):\(.id[13:15])  ·  \(if .words == "" then "(not transcribed yet)" else .words end)  #\(.id[-4:])\t\(.id)"
  ' <<<"$drafts")
  entries+=$'\n'"Mode: $(mode_label "$(current_mode)") ($(current_mode)): switch"$'\t'"@mode"
  choice=$(cut -f1 <<<"${entries#$'\n'}" | "${launcher[@]}") || exit 0
  [[ -n $choice ]] || exit 0
  line=$(awk -F'\t' -v c="$choice" '$1 == c { print; exit }' <<<"$entries")
  id=$(cut -f2 <<<"$line")
  [[ -n $id ]] || exit 1
  if [[ $id == @mode ]]; then
    set_mode toggle
    return
  fi
  action=$(printf '%s\n' "Copy text" "Type text into the focused window" \
    "Retranscribe and copy" "Discard" | "${launcher[@]}") || exit 0
  case "$action" in
  "Copy text")
    if err=$("$cfg_stream" recover "$id" --copy 2>&1 >/dev/null); then
      notify low 3000 "Copied the draft's text"
    else
      notify critical 8000 "Couldn't copy: $(tail -n 2 <<<"$err")"
    fi
    ;;
  "Type text"*)
    err=$("$cfg_stream" recover "$id" --type --delay 0.5 2>&1 >/dev/null) ||
      notify critical 8000 "Couldn't type: $(tail -n 2 <<<"$err")"
    ;;
  "Retranscribe and copy")
    notify low 3000 "Transcribing the draft again…"
    if err=$("$cfg_stream" recover "$id" --fresh --copy 2>&1 >/dev/null); then
      notify low 3000 "Transcribed again and copied"
    else
      notify critical 8000 "Retranscription failed: $(tail -n 2 <<<"$err")"
    fi
    ;;
  Discard)
    [[ $(printf '%s\n' "Keep it" "Discard this draft for good" | "${launcher[@]}") == Discard* ]] || return 0
    "$cfg_stream" discard "$id" >/dev/null 2>&1 && notify low 2000 "Draft discarded"
    ;;
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
recover | drafts | discard) exec "$cfg_stream" "$@" ;;
mode)
  case "${2:-}" in
  "") echo "$(current_mode) ($(mode_label "$(current_mode)"))" ;;
  batch | stream | toggle) set_mode "$2" ;;
  *)
    echo "usage: dictate mode [batch|stream|toggle]" >&2
    exit 2
    ;;
  esac
  ;;
menu) menu ;;
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
  echo "mode now: $(current_mode)"
  "$cfg_stream" drafts
  ;;
*)
  echo "usage: dictate press|release|toggle|cancel|mode|status|drafts|recover|discard|menu|file WAV|backends" >&2
  exit 2
  ;;
esac
