# headless-modes core: desk / headless / bag from "external display?" and
# "on AC?". Every path and setting comes from the environment (set by
# headless-modes.nix; headless-modes-test.sh runs it on a fake sysfs tree).
#
#   detect             print "<mode> display=<0|1> ac=<0|1> override=<o>"
#   apply              mute/unmute built-in inputs, set CPU limits + profile
#   hot-check          one hot-alert sample (timer, every 30 s)
#   set-override MODE  auto | bag | full (power tier only; /run, so a reboot
#                      returns to auto)
set -u
SYS=${HM_SYS:-/sys}
RUN=${HM_RUN:-/run/headless-mode}

log() { echo "$*"; }

# An external display is any connected connector not matching the ignore
# globs (the broken internal panel stays "connected").
display() {
  local s conn g
  for s in "$SYS"/class/drm/card*-*/status; do
    [ -e "$s" ] || continue
    conn=${s%/status}
    conn=${conn##*/}
    conn=${conn#card*-}
    for g in ${HM_IGNORE_CONNECTORS:-}; do
      # shellcheck disable=SC2254
      case $conn in $g) continue 2 ;; esac
    done
    [ "$(cat "$s")" = connected ] && return 0
  done
  return 1
}

on_ac() {
  local ps
  for ps in "$SYS"/class/power_supply/*; do
    [ -e "$ps/type" ] || continue
    case $(cat "$ps/type") in
      Mains | USB) [ "$(cat "$ps/online" 2>/dev/null)" = 1 ] && return 0 ;;
    esac
  done
  return 1
}

override() {
  local o
  o=$(cat "$RUN/override" 2>/dev/null || true)
  case $o in bag | full) echo "$o" ;; *) echo auto ;; esac
}

detect() {
  local d=0 a=0 o mode
  display && d=1
  on_ac && a=1
  o=$(override)
  if [ "$o" = bag ] || { [ "$o" = auto ] && [ $d = 0 ] && [ $a = 0 ]; }; then
    mode=bag
  elif [ $d = 1 ]; then
    mode=desk
  else
    mode=headless
  fi
  echo "$mode display=$d ac=$a override=$o"
}

write_if_diff() { # <file> <value>
  [ -w "$1" ] || [ -e "$1" ] || return 0
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0
  if echo "$2" >"$1" 2>/dev/null; then
    log "set $1 = $2"
  else
    log "could not write $2 to $1"
  fi
}

# Built-in inputs follow the display, whatever the power tier.
apply_inputs() { # <0|1>
  local dev name
  for dev in "$SYS"/class/input/input*; do
    [ -e "$dev/inhibited" ] || continue
    name=$(cat "$dev/name" 2>/dev/null || true)
    if [[ $name =~ ${HM_INPUT_REGEX:-^$} ]]; then
      write_if_diff "$dev/inhibited" "$1"
    fi
  done
}

# Package RAPL zones (intel-rapl:N, intel-rapl-mmio:N): constraint 0 is the
# long-term limit, 1 the short-term one. The first cap saves the original
# values; leaving bag restores them.
apply_rapl() { # <bag|full>
  local zone n f orig watts
  for zone in "$SYS"/class/powercap/intel-rapl:[0-9] "$SYS"/class/powercap/intel-rapl-mmio:[0-9]; do
    [ -d "$zone" ] || continue
    for n in 0 1; do
      f=$zone/constraint_${n}_power_limit_uw
      [ -e "$f" ] || continue
      orig=$RUN/rapl-${zone##*/}-$n.orig
      if [ "$1" = bag ]; then
        [ -e "$orig" ] || cat "$f" >"$orig"
        if [ $n = 0 ]; then watts=$HM_BAG_LONG_W; else watts=$HM_BAG_SHORT_W; fi
        write_if_diff "$f" $((watts * 1000000))
      elif [ -e "$orig" ]; then
        write_if_diff "$f" "$(cat "$orig")"
        rm -f "$orig"
      fi
    done
  done
}

apply() {
  local line mode d tier
  mkdir -p "$RUN"
  line=$(detect)
  mode=${line%% *}
  d=${line#*display=}
  d=${d%% *}
  log "mode: $line"
  if [ "$d" = 1 ]; then apply_inputs 0; else apply_inputs 1; fi
  if [ "$mode" = bag ]; then tier=bag; else tier=full; fi
  apply_rapl $tier
  if [ -n "${HM_PPD:-}" ]; then
    if [ $tier = bag ]; then
      "$HM_PPD" set power-saver || log "power-saver profile failed"
    else
      "$HM_PPD" set "${HM_FULL_PROFILE:-performance}" || log "profile failed"
    fi
  fi
  echo "$mode" >"$RUN/mode"
}

pkg_temp() { # millidegrees of the CPU package, or nothing
  local z
  for z in "$SYS"/class/thermal/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = x86_pkg_temp ] || continue
    cat "$z/temp" 2>/dev/null && return 0
  done
  return 1
}

# Push once the package stayed above HM_HOT_C for HM_HOT_COUNT samples, then
# not again for HM_HOT_COOLDOWN s. A failed push is retried on the next sample.
hot_check() {
  local t now count last topic url
  mkdir -p "$RUN"
  t=$(pkg_temp) || return 0
  now=${HM_NOW:-$(date +%s)}
  count=$(cat "$RUN/hot-count" 2>/dev/null || echo 0)
  if [ "$t" -lt $((HM_HOT_C * 1000)) ]; then
    echo 0 >"$RUN/hot-count"
    return 0
  fi
  count=$((count + 1))
  echo "$count" >"$RUN/hot-count"
  [ "$count" -ge "$HM_HOT_COUNT" ] || return 0
  last=$(cat "$RUN/hot-last" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "$HM_HOT_COOLDOWN" ] || return 0
  log "CPU package at $((t / 1000)) °C (mode $(cat "$RUN/mode" 2>/dev/null || echo unknown))"
  [ -n "${HM_NTFY_TOPIC_FILE:-}" ] && [ -r "$HM_NTFY_TOPIC_FILE" ] || return 0
  topic=$(tr -d '[:space:]' <"$HM_NTFY_TOPIC_FILE")
  case $topic in
    https://* | http://*) url=$topic ;;
    *) url="https://ntfy.sh/$topic" ;;
  esac
  if "${HM_CURL:-curl}" -fsS -m 20 -H "Title: $(uname -n) is hot" -H "Tags: fire" -H "Priority: high" \
    -d "CPU package $((t / 1000)) °C, mode $(cat "$RUN/mode" 2>/dev/null || echo unknown)" "$url" >/dev/null; then
    echo "$now" >"$RUN/hot-last"
  else
    log "hot alert push failed"
  fi
  return 0
}

case "${1:-}" in
  detect) detect ;;
  apply) apply ;;
  hot-check) hot_check ;;
  set-override)
    mkdir -p "$RUN"
    case "${2:-}" in
      bag | full) echo "$2" >"$RUN/override" ;;
      auto) rm -f "$RUN/override" ;;
      *)
        echo "set-override: auto|bag|full" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "usage: headless-modes.sh detect|apply|hot-check|set-override MODE" >&2
    exit 2
    ;;
esac
