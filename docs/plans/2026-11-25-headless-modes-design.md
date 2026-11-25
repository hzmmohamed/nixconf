# Headless modes for butternut (desk / headless / bag)

Short design, 2026-11-25. Replaces the manual `bag-mode` command from PR #7.

## Why

butternut gets carried running, in a backpack, while agents keep working and
Pollen may send dictation to its GPU. Its lid can't close, so keys get
pressed, and in a bag it has no ventilation. Whether it's headless (no
external monitor) and on battery says where it is; no command to remember.

- Headless, any power: the built-in keyboard must not act, and the power
  button must not switch it off by accident.
- In a bag: keep it cool and quiet, but keep everything running (agents,
  on-demand GPU dictation).

Non-goals: pausing agents or builds, switching the dGPU off (it idles at
~3 W and dictation needs it), custom fan curves (in a bag, a slower fan means
more heat; cut heat at the source instead).
Anti-goal: anything that can leave it unreachable or hung (no `dgpu_disable`,
no automatic suspend).

## Approaches

1. **Event-driven apply (picked).** udev events (DRM hotplug, AC
   plug/unplug) and boot start a oneshot that works out the mode and writes a
   handful of sysfs knobs. No daemon; every change is in the journal.
2. Temperature-feedback daemon that lowers the power cap toward a target:
   adapts better, but more code, and a fixed ~15 W cap already runs cool.
3. Fixed limits whenever on battery: simplest, but also throttles a café
   table with a monitor, and doesn't tie the keyboard to headless.

## Design

Mode = `desk` (external display connected) | `headless` (none, on AC) |
`bag` (none, on battery). Display detection reuses `detectDisplay`'s
connector logic.

| | desk | headless | bag |
|---|---|---|---|
| Built-in keyboard + touchpad (`/sys/class/input/*/inhibited`) | on | muted | muted |
| CPU | ppd `performance` | `performance` | ppd `power-saver` (firmware "quiet") + RAPL long-term cap ~15 W |
| dGPU | as now | as now | as now (builder call: ASUS `nv_dynamic_boost`/`nv_temp_target` already sit at their minimums, 5 / 75) |

USB keyboards are never muted. Muting the built-in keyboard also stops stray
Ctrl+Alt+Del and SysRq presses from it.

Power button (static, every mode; my call): short press ignored, long press
powers off (logind `HandlePowerKey=ignore`, `HandlePowerKeyLongPress=poweroff`);
the firmware's long hold stays as the last resort. Shut down at the desk from
the menu or `systemctl poweroff`.

Hot alert: every 30 s, if the CPU package stays above ~90 °C for two checks,
ntfy push to the phone (existing agents topic), at most once per 15 min.
Linux throttles and the firmware powers off at critical on its own.

Override: `headless-mode status|auto|bag|full` (state in /run, so a reboot
returns to auto), for an unplugged café table where full speed is wanted.
Launcher entry on desktop hosts.

Lives in `features/headless-boot.nix` as `preferences.headlessBoot.modes.*`
(per-mode knobs as options, with ASUS/RAPL paths skipped when absent), enabled
on butternut; PR #7's `bag-mode` is replaced on the same branch.

## Left to the builder

Exact defaults (watts, temps), which input devices count as built-in (by name
match vs. bus), restoring previous values vs. writing fixed desk values.
Values that need root to test (RAPL write, inhibited, ASUS knobs) get a short
on-device check list for the user after deploy.
