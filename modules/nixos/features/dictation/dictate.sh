# dictate: push-to-talk dictation into the focused window (Sway).
#
#   dictate press      key down: start recording, or stop if already latched
#   dictate release    key up: held >= tap threshold -> stop and transcribe;
#                      a short tap latches (toggle mode: press again to stop)
#   dictate toggle     start / stop (for a single binding or a script)
#   dictate cancel     stop recording and discard it
#   dictate status     waybar JSON (idle / recording / transcribing)
#   dictate file WAV   transcribe a 16 kHz WAV and print the text
#   dictate backends   show which engine a dictation would use right now
#
# Backend per dictation: the first reachable server in $servers (whisper.cpp
# `whisper-server`, multilingual, e.g. butternut's GPU), probed while you
# speak; otherwise the local engine: Parakeet on the CPU (English; started
# on demand by socket activation, exits when idle) or local whisper.cpp for
# other languages. The language follows the active keyboard layout.
#
# Config comes from the Nix-generated preamble; every value can be
# overridden from the environment for testing, e.g. DICTATE_SERVERS= (empty)
# forces the local engine, DICTATE_LANG=ar forces Arabic.

servers=()
read -r -a servers <<<"${DICTATE_SERVERS-$cfg_servers}"
lang_override=${DICTATE_LANG:-}
local_socket=${DICTATE_LOCAL_SOCKET:-$cfg_local_socket}
output_mode=${DICTATE_OUTPUT:-$cfg_output}
state_dir="${XDG_RUNTIME_DIR:?}/dictate"
wav="$state_dir/audio.wav"

mkdir -p "$state_dir"
exec 9>"$state_dir/lock"

lock() { flock 9; }
unlock() { flock -u 9; }
now_ms() { date +%s%3N; }
get() { cat "$state_dir/$1" 2>/dev/null || true; }
put() { printf '%s' "$2" >"$state_dir/$1"; }
clear_session() { rm -f "$state_dir"/{rec-pid,t0,latched,backend,probe-done,lang}; }

refresh_bar() {
  systemctl --user kill --kill-whom=main -s "SIGRTMIN+$cfg_waybar_signal" waybar.service >/dev/null 2>&1 || true
}

# One replaceable notification per session (swaync / any notification daemon).
notify() { # urgency timeout-ms body
  local id args
  id=$(get notify-id)
  args=(-a Dictation -i audio-input-microphone -u "$1" -t "$2" -p)
  [[ -n $id ]] && args+=(-r "$id")
  id=$(notify-send "${args[@]}" "Dictation" "$3" 2>/dev/null) || return 0
  put notify-id "$id"
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

# Probe the servers in parallel; the first reachable one in list order wins.
# A reachable server that is cold (idle-stopped) loads its model during
# this request, i.e. while you are still speaking.
probe() {
  local i url pids=()
  rm -f "$state_dir"/ok.*
  for i in "${!servers[@]}"; do
    url=${servers[$i]}
    (curl -fsS -o /dev/null --connect-timeout 0.6 -m 20 "$url/" 2>/dev/null && : >"$state_dir/ok.$i") &
    pids+=($!)
  done
  [[ ${#pids[@]} -gt 0 ]] && wait "${pids[@]}"
  for i in "${!servers[@]}"; do
    if [[ -e $state_dir/ok.$i ]]; then
      put backend "${servers[$i]}"
      : >"$state_dir/probe-done"
      return
    fi
  done
  put backend local
  : >"$state_dir/probe-done"
  # Warm the local engine now (socket activation loads the model).
  [[ $1 == "$cfg_local_lang" ]] && warm_local
  return 0
}

warm_local() {
  curl -fsS -o /dev/null -m 60 --unix-socket "$local_socket" http://local/ready 2>/dev/null || true
}

backend_label() {
  case "$1" in
  local) echo "this machine" ;;
  *) sed -E 's#^[a-z]+://##; s#[:/].*##' <<<"$1" ;;
  esac
}

clean_text() {
  # Drop whisper's non-speech tags ([BLANK_AUDIO], [Music], (silence)…),
  # join lines, squeeze spaces.
  sed -E 's/\[[^]]*\]//g; s/^[[:space:]]*\([^)]*\)[[:space:]]*$//' |
    tr '\n' ' ' | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

transcribe_remote() { # url lang file
  local args=(-F "file=@$3" -F response_format=json -F "language=$2" -F temperature=0.0 -F temperature_inc=0.2)
  [[ -n $cfg_prompt ]] && args+=(-F "prompt=$cfg_prompt")
  curl -fsS --connect-timeout 1 -m 120 "${args[@]}" "$1/inference" | jq -er '.text'
}

transcribe_local() { # lang file
  if [[ $1 == "$cfg_local_lang" ]]; then
    curl -fsS -m 120 --unix-socket "$local_socket" -H 'Content-Type: audio/wav' \
      --data-binary "@$2" http://local/inference | jq -er '.text'
  elif [[ -n $cfg_whisper_model ]]; then
    whisper-cli -m "$cfg_whisper_model" -l "$1" -t "$cfg_threads" -nt -np -f "$2" 2>/dev/null
  else
    echo "no local model for language '$1' (needs a server)" >&2
    return 1
  fi
}

# transcribe BACKEND LANG FILE: the chosen backend, then the local engine.
transcribe() {
  local text
  if [[ $1 != local ]]; then
    if text=$(transcribe_remote "$1" "$2" "$3"); then
      clean_text <<<"$text"
      return
    fi
    echo "dictate: $(backend_label "$1") failed, falling back to the local engine" >&2
  fi
  text=$(transcribe_local "$2" "$3") || return 1
  clean_text <<<"$text"
}

type_text() {
  local text="$1 "
  [[ $cfg_append_space == 1 ]] || text=$1
  printf '%s' "$1" >"$state_dir/last.txt"
  if [[ $output_mode == paste ]]; then
    wl-copy -- "$text" && wtype -M ctrl -M shift -k v -m shift -m ctrl && return
  elif wtype -- "$text"; then
    return
  fi
  wl-copy -- "$1" && notify normal 6000 "Couldn't type; copied to the clipboard: $1"
}

start() {
  local lang t0
  lang=$(current_lang)
  t0=$(now_ms)
  clear_session
  rm -f "$wav"
  put t0 "$t0"
  put lang "$lang"
  # pw-record finalises the WAV header on SIGTERM; `timeout` forwards it.
  (
    exec 9>&-
    timeout -s TERM "$cfg_max_sec" pw-record --rate 16000 --channels 1 --format s16 \
      --media-role Communication "$wav" 2>/dev/null &
    put rec-pid $!
    wait $! || true
    "$0" auto-stop "$t0"
  ) &
  disown
  put state recording
  unlock
  refresh_bar
  notify low 0 "Listening ($(lang_label "$lang"))…"
  (
    exec 9>&-
    probe "$lang" &
  )
}

# Called with the lock held and state == recording.
stop() {
  local pid lang backend text i size
  put state transcribing
  unlock
  refresh_bar
  pid=$(get rec-pid)
  [[ -n $pid ]] && { kill -TERM "$pid" 2>/dev/null || true; }
  for i in $(seq 40); do
    if [[ -z $pid ]] || ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.05
  done
  lang=$(get lang)
  size=$(stat -c %s "$wav" 2>/dev/null || echo 0)
  if ((size < 44 + 16000)); then # < 0.5 s of audio
    finish
    notify low 1500 "Too short, nothing to transcribe"
    return
  fi
  for i in $(seq 200); do # the probe (incl. a cold server) for up to 20 s
    [[ -e $state_dir/probe-done ]] && break
    sleep 0.1
  done
  backend=$(get backend)
  [[ -n $backend ]] || backend=local
  notify low 0 "Transcribing on $(backend_label "$backend") ($(lang_label "$lang"))…"
  if ! text=$(transcribe "$backend" "$lang" "$wav" 2>"$state_dir/error.log"); then
    finish
    notify critical 8000 "Transcription failed: $(tail -n 3 "$state_dir/error.log")"
    return
  fi
  finish
  if [[ -z $text ]]; then
    notify low 1500 "Nothing heard"
    return
  fi
  type_text "$text"
  notify low 3000 "$text"
}

finish() {
  lock
  put state idle
  clear_session
  unlock
  refresh_bar
}

cancel() {
  local pid
  pid=$(get rec-pid)
  put state idle
  clear_session
  unlock
  [[ -n $pid ]] && { kill -TERM "$pid" 2>/dev/null || true; }
  rm -f "$wav"
  refresh_bar
  notify low 1000 "Cancelled"
}

status() {
  local state lang backend
  state=$(get state)
  lang=$(get lang)
  case "$state" in
  recording)
    printf '{"text":"󰍬","class":"recording","tooltip":"Dictating (%s): release, or press again, to stop"}\n' "$(lang_label "$lang")"
    ;;
  transcribing)
    backend=$(get backend)
    printf '{"text":"󰔟","class":"transcribing","tooltip":"Transcribing on %s"}\n' "$(backend_label "${backend:-local}")"
    ;;
  *) printf '{"text":""}\n' ;;
  esac
}

cmd=${1:-toggle}
case "$cmd" in
press)
  lock
  case "$(get state)" in
  recording) stop ;;
  transcribing) ;;
  *) start ;;
  esac
  ;;
release)
  lock
  [[ $(get state) == recording && $(get latched) != 1 ]] || exit 0
  t0=$(get t0)
  if (($(now_ms) - ${t0:-0} < cfg_tap_ms)); then
    put latched 1
    unlock
    notify low 0 "Listening ($(lang_label "$(get lang)"))… press again to stop"
  else
    stop
  fi
  ;;
toggle)
  lock
  case "$(get state)" in
  recording) stop ;;
  transcribing) ;;
  *) start ;;
  esac
  ;;
auto-stop) # the recorder ended (max duration): stop if it's still our session
  lock
  [[ $(get state) == recording && $(get t0) == "${2:-}" ]] || exit 0
  stop
  ;;
cancel)
  lock
  [[ $(get state) == recording ]] || exit 0
  cancel
  ;;
status) status ;;
file)
  [[ -r ${2:-} ]] || {
    echo "usage: dictate file WAV" >&2
    exit 2
  }
  lang=$(current_lang)
  state_dir=$(mktemp -d) # keep a running dictation's state untouched
  probe "$lang"
  backend=$(get backend)
  rm -rf "$state_dir"
  echo "dictate: $(backend_label "$backend") ($lang)" >&2
  transcribe "$backend" "$lang" "$2"
  echo
  ;;
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
  ;;
*)
  echo "usage: dictate press|release|toggle|cancel|status|file WAV|backends" >&2
  exit 2
  ;;
esac
