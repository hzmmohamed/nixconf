# set-wallpaper — the single entry point for wallpaper (and, with the
# wallpaper theme source, palette) changes. Body of a writeShellApplication;
# the Nix preamble defines DEFAULT_LIGHT, DEFAULT_DARK, WALLPAPER_SOURCE
# ("catppuccin" | "wallpaper"), TRANSITION_DURATION and THEME_MODE.
#
#   set-wallpaper FILE           apply FILE (pinned: survives light/dark switches)
#   set-wallpaper --mode M       darkman: default for M unless pinned, then theme-mode M
#   set-wallpaper --restore      login: re-apply the recorded/default wallpaper
#   set-wallpaper --unpin        back to the light/dark default pair
#   set-wallpaper --info         current file + sidecar attribution as JSON
#
# State: ${XDG_STATE_HOME:-~/.local/state}/wallpaper/current.json
#   {file, sidecar, pinned, set_at}. Sidecar: "<FILE>.json" next to FILE.

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper"
state="$state_dir/current.json"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

log() { echo "set-wallpaper: $*" >&2; }
die() {
  log "$*"
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: set-wallpaper FILE
       set-wallpaper --mode light|dark
       set-wallpaper --restore | --unpin | --info
EOF
  exit 2
}

# darkman and other user units may run before WAYLAND_DISPLAY is imported.
ensure_wayland() {
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    local s
    for s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
      case "$s" in *.lock) continue ;; esac
      if [ -S "$s" ]; then
        WAYLAND_DISPLAY="${s##*/}"
        export WAYLAND_DISPLAY
        break
      fi
    done
  fi
  [ -n "${WAYLAND_DISPLAY:-}" ]
}

daemon_up() { ensure_wayland && awww query >/dev/null 2>&1; }

state_get() { jq -r "$1 // empty" "$state" 2>/dev/null || true; }

default_for() {
  case "$1" in
    light) echo "$DEFAULT_LIGHT" ;;
    *) echo "$DEFAULT_DARK" ;;
  esac
}

is_default() { [ "$1" = "$DEFAULT_LIGHT" ] || [ "$1" = "$DEFAULT_DARK" ]; }

sidecar_of() { if [ -f "$1.json" ]; then echo "$1.json"; fi; }

current_mode() {
  local m
  m="$("$THEME_MODE" get 2>/dev/null || true)"
  case "$m" in light | dark) echo "$m" ;; *) echo light ;; esac
}

# Show FILE on every output (no-op if all outputs already show it).
display() {
  if ! daemon_up; then
    log "awww-daemon not reachable; state recorded, will apply on --restore"
    return 0
  fi
  if ! awww query 2>/dev/null | grep -vF "image: $1" | grep -q .; then
    return 0
  fi
  awww img "$1" --transition-type fade --transition-duration "$TRANSITION_DURATION" \
    --transition-fps 60 || log "awww img failed for $1"
}

# Wallpaper theme source: (re)generate the palette for FILE. No-op otherwise.
palette() {
  [ "$WALLPAPER_SOURCE" = wallpaper ] || return 0
  "$THEME_MODE" generate "$1" || log "palette generation failed; Catppuccin fallback in use"
}

# write_state FILE PINNED — only touches the file when something changed.
write_state() {
  local sc tmp
  sc="$(sidecar_of "$1")"
  if [ "$(state_get .file)" = "$1" ] && [ "$(state_get .pinned)" = "$2" ] &&
    [ "$(state_get .sidecar)" = "$sc" ]; then
    return 0
  fi
  mkdir -p "$state_dir"
  tmp="$state.tmp.$$"
  jq -n --arg file "$1" --arg sidecar "$sc" --argjson pinned "$2" \
    --arg set_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{file: $file, sidecar: (if $sidecar == "" then null else $sidecar end),
      pinned: $pinned, set_at: $set_at}' >"$tmp"
  mv -f "$tmp" "$state"
}

# The wallpaper for MODE: the pinned file if it still exists, else the default.
resolve() {
  local file
  file="$(state_get .file)"
  if [ "$(state_get .pinned)" = true ] && [ -f "$file" ]; then
    printf '%s\ttrue\n' "$file"
  else
    printf '%s\tfalse\n' "$(default_for "$1")"
  fi
}

lock() {
  mkdir -p "$state_dir"
  exec 9>"$XDG_RUNTIME_DIR/set-wallpaper.lock"
  flock -w 60 9 || die "another set-wallpaper is still running"
}

cmd_set() {
  local file pinned=true
  file="$(realpath -e -- "$1" 2>/dev/null)" || die "no such file: $1"
  [ -f "$file" ] || die "not a file: $file"
  is_default "$file" && pinned=false
  lock
  display "$file"
  if [ "$WALLPAPER_SOURCE" = wallpaper ]; then
    palette "$file"
    "$THEME_MODE" apply || true
  fi
  write_state "$file" "$pinned"
}

cmd_mode() {
  local mode="$1" file pinned
  lock
  IFS=$'\t' read -r file pinned < <(resolve "$mode")
  display "$file"
  palette "$file"
  "$THEME_MODE" "$mode" || log "theme-mode $mode failed"
  write_state "$file" "$pinned"
}

cmd_restore() {
  local i file pinned
  lock
  for i in $(seq 1 30); do
    daemon_up && break
    [ "$i" = 30 ] && log "awww-daemon not up after 15s"
    sleep 0.5
  done
  IFS=$'\t' read -r file pinned < <(resolve "$(current_mode)")
  display "$file"
  if [ "$WALLPAPER_SOURCE" = wallpaper ]; then
    palette "$file"
    "$THEME_MODE" apply || true
  fi
  write_state "$file" "$pinned"
}

cmd_unpin() {
  if [ -f "$state" ]; then
    lock
    jq '.pinned = false' "$state" >"$state.tmp.$$" && mv -f "$state.tmp.$$" "$state"
    flock -u 9
  fi
  cmd_mode "$(current_mode)"
}

cmd_info() {
  local file pinned set_at sc
  if [ -f "$state" ]; then
    file="$(state_get .file)"
    pinned="$(state_get .pinned)"
    set_at="$(state_get .set_at)"
  else
    IFS=$'\t' read -r file pinned < <(resolve "$(current_mode)")
    set_at=""
  fi
  sc="$(sidecar_of "$file")"
  jq -n --arg file "$file" --argjson pinned "${pinned:-false}" --arg set_at "$set_at" \
    --arg mode "$(current_mode)" --arg sidecar "$sc" \
    --argjson attribution "$(if [ -n "$sc" ]; then jq -c . "$sc" 2>/dev/null || echo null; else echo null; fi)" \
    '{file: $file, sidecar: (if $sidecar == "" then null else $sidecar end),
      pinned: $pinned, set_at: (if $set_at == "" then null else $set_at end),
      mode: $mode, attribution: $attribution}'
}

case "${1:-}" in
  --mode)
    case "${2:-}" in light | dark) cmd_mode "$2" ;; *) usage ;; esac
    ;;
  --restore) cmd_restore ;;
  --unpin) cmd_unpin ;;
  --info) cmd_info ;;
  -h | --help | "") usage ;;
  -*) usage ;;
  *) cmd_set "$1" ;;
esac
