# Tests for headless-modes.sh against a fake sysfs tree.
# Usage: bash headless-modes-test.sh <path to headless-modes.sh>
set -eu
core=$1
T=$(mktemp -d)
fails=0

ok() { echo "ok   $1"; }
bad() {
  echo "FAIL $1"
  fails=$((fails + 1))
}
eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2', got '$3'"; fi
}

reset() {
  rm -rf "$T/sys" "$T/run" "$T/calls"
  : >"$T/calls"
  S=$T/sys
  mkdir -p "$S/class/drm/card1-eDP-1" "$S/class/drm/card1-HDMI-A-1" \
    "$S/class/power_supply/ACAD" "$S/class/power_supply/BAT1" \
    "$S/class/powercap/intel-rapl:0" "$S/class/thermal/thermal_zone3"
  echo connected >"$S/class/drm/card1-eDP-1/status"
  echo disconnected >"$S/class/drm/card1-HDMI-A-1/status"
  echo Mains >"$S/class/power_supply/ACAD/type"
  echo 0 >"$S/class/power_supply/ACAD/online"
  echo Battery >"$S/class/power_supply/BAT1/type"
  mk_input input0 "AT Translated Set 2 keyboard"
  mk_input input12 "ASUP1205:00 093A:2003 Touchpad"
  mk_input input30 "Logitech USB Keyboard"
  echo 45000000 >"$S/class/powercap/intel-rapl:0/constraint_0_power_limit_uw"
  echo 95000000 >"$S/class/powercap/intel-rapl:0/constraint_1_power_limit_uw"
  echo x86_pkg_temp >"$S/class/thermal/thermal_zone3/type"
  echo 50000 >"$S/class/thermal/thermal_zone3/temp"
}
mk_input() {
  mkdir -p "$S/class/input/$1"
  echo "$2" >"$S/class/input/$1/name"
  echo 0 >"$S/class/input/$1/inhibited"
}
hdmi() { echo "$1" >"$S/class/drm/card1-HDMI-A-1/status"; }
ac() { echo "$1" >"$S/class/power_supply/ACAD/online"; }
inh() { cat "$S/class/input/$1/inhibited"; }
rapl() { echo "$(cat "$S/class/powercap/intel-rapl:0/constraint_0_power_limit_uw")/$(cat "$S/class/powercap/intel-rapl:0/constraint_1_power_limit_uw")"; }
last_ppd() { grep '^ppd' "$T/calls" | tail -n1; }

cat >"$T/ppd" <<EOF
#!/bin/sh
echo "ppd \$*" >>"$T/calls"
EOF
cat >"$T/curl" <<EOF
#!/bin/sh
echo "curl \$*" >>"$T/calls"
exit \${CURL_EXIT:-0}
EOF
chmod +x "$T/ppd" "$T/curl"

export HM_SYS="$T/sys" HM_RUN="$T/run" HM_PPD="$T/ppd" HM_CURL="$T/curl"
export HM_INPUT_REGEX='^(AT Translated Set 2 keyboard|Asus WMI hotkeys|.*Touchpad)$'
export HM_IGNORE_CONNECTORS='eDP-* LVDS-* DSI-*'
export HM_BAG_LONG_W=15 HM_BAG_SHORT_W=25 HM_FULL_PROFILE=performance
export HM_HOT_C=90 HM_HOT_COUNT=2 HM_HOT_COOLDOWN=900
echo topic >"$T/topic"
export HM_NTFY_TOPIC_FILE="$T/topic"
run() { bash "$core" "$@"; }
mode() { run detect | cut -d' ' -f1; }

echo "== 1: monitor, battery → desk"
reset
hdmi connected
eq "1 detect" "desk display=1 ac=0 override=auto" "$(run detect)"
run apply >/dev/null
eq "1 keyboard on" 0 "$(inh input0)"
eq "1 touchpad on" 0 "$(inh input12)"
eq "1 rapl unchanged" 45000000/95000000 "$(rapl)"
eq "1 ppd" "ppd set performance" "$(last_ppd)"

echo "== 2: no monitor, AC → headless"
reset
ac 1
eq "2 detect" headless "$(mode)"
run apply >/dev/null
eq "2 keyboard muted" 1 "$(inh input0)"
eq "2 touchpad muted" 1 "$(inh input12)"
eq "2 usb keyboard on" 0 "$(inh input30)"
eq "2 rapl unchanged" 45000000/95000000 "$(rapl)"

echo "== 3: no monitor, battery → bag"
reset
eq "3 detect" bag "$(mode)"
run apply >/dev/null
eq "3 keyboard muted" 1 "$(inh input0)"
eq "3 rapl capped" 15000000/25000000 "$(rapl)"
eq "3 ppd" "ppd set power-saver" "$(last_ppd)"
run apply >/dev/null
eq "3b orig kept" "45000000 95000000" "$(cat "$T/run/rapl-intel-rapl:0-0.orig") $(cat "$T/run/rapl-intel-rapl:0-1.orig")"

echo "== 4: AC back → headless, limits restored"
ac 1
eq "4 detect" headless "$(mode)"
run apply >/dev/null
eq "4 rapl restored" 45000000/95000000 "$(rapl)"
eq "4 ppd" "ppd set performance" "$(last_ppd)"
eq "4 keyboard still muted" 1 "$(inh input0)"

echo "== 4b: monitor plugged → desk, keyboard back"
hdmi connected
run apply >/dev/null
eq "4b keyboard on" 0 "$(inh input0)"

echo "== 5: only the internal panel connected is not a display"
reset
ac 1
eq "5 detect" "headless display=0 ac=1 override=auto" "$(run detect)"

echo "== 6: overrides"
reset
run set-override full
eq "6 full on battery" "headless display=0 ac=0 override=full" "$(run detect)"
run apply >/dev/null
eq "6 full: keyboard muted" 1 "$(inh input0)"
eq "6 full: rapl original" 45000000/95000000 "$(rapl)"
hdmi connected
run set-override bag
eq "6 bag on desk" bag "$(mode)"
run apply >/dev/null
eq "6 bag: keyboard on (display)" 0 "$(inh input0)"
eq "6 bag: rapl capped" 15000000/25000000 "$(rapl)"
echo junk >"$T/run/override"
eq "6 junk → auto" "desk display=1 ac=0 override=auto" "$(run detect)"
run set-override auto
eq "6 auto clears" auto "$(run detect | sed 's/.*override=//')"

echo "== 7: bare tree (no rapl/thermal/inputs) applies cleanly"
reset
rm -rf "$S/class/powercap" "$S/class/input" "$S/class/thermal"
if run apply >/dev/null 2>&1; then ok "7 apply exit 0"; else bad "7 apply failed"; fi
if run hot-check >/dev/null 2>&1; then ok "7 hot-check exit 0"; else bad "7 hot-check failed"; fi

echo "== 8: hot alert"
reset
curls() { grep -c '^curl' "$T/calls" || true; }
temp() { echo "$1" >"$S/class/thermal/thermal_zone3/temp"; }
temp 95000
HM_NOW=1000 run hot-check >/dev/null
eq "8 first hot check: no push yet" 0 "$(curls)"
HM_NOW=1030 run hot-check >/dev/null
eq "8 second hot check: push" 1 "$(curls)"
HM_NOW=1060 run hot-check >/dev/null
HM_NOW=1090 run hot-check >/dev/null
eq "8 cooldown: no more pushes" 1 "$(curls)"
HM_NOW=2000 run hot-check >/dev/null
HM_NOW=2030 run hot-check >/dev/null
eq "8 after cooldown: second push" 2 "$(curls)"
temp 80000
HM_NOW=3000 run hot-check >/dev/null
temp 95000
HM_NOW=3030 run hot-check >/dev/null
eq "8 cool reading resets the count" 2 "$(curls)"
if CURL_EXIT=1 HM_NOW=5000 run hot-check >/dev/null 2>&1 && CURL_EXIT=1 HM_NOW=5030 run hot-check >/dev/null 2>&1; then
  ok "8 curl failure → exit 0"
else bad "8 curl failure failed the check"; fi
HM_NTFY_TOPIC_FILE='' HM_NOW=9000 run hot-check >/dev/null
HM_NTFY_TOPIC_FILE='' HM_NOW=9030 run hot-check >/dev/null
eq "8 failed pushes retry, no topic: journal only" 4 "$(curls)"

rm -rf "$T"
if [ "$fails" -gt 0 ]; then
  echo "$fails failure(s)"
  exit 1
fi
echo "all ok"
