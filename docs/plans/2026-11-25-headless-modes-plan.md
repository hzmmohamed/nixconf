# Headless Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** butternut picks desk / headless / bag by itself (display + AC) and
mutes the built-in keyboard when headless, caps CPU power in a bag, ignores a
short power-key press, and pushes a hot alert.

**Architecture:** one bash core script (`headless-modes.sh`) with every path
overridable by env, so a flake check runs it against a fake sysfs tree. A new
feature `headless-modes.nix` wires it: oneshot `headless-mode-apply.service`
restarted by udev (DRM hotplug, power_supply change, input add) and at boot, a
30 s timer for the hot alert, logind power-key settings, a `headless-mode`
user CLI + launcher entry. PR #7's `bag-mode` is dropped from the branch.

**Tech Stack:** NixOS module (flake-parts / import-tree), bash, sysfs
(`input/*/inhibited`, `powercap/intel-rapl*`, `power_supply`, `drm`,
`thermal`), power-profiles-daemon, ntfy over curl.

**Spec:** `docs/plans/2026-11-25-headless-modes-design.md`

## Global Constraints

- Builder call (recorded in the spec): ASUS `nv_dynamic_boost`/`nv_temp_target`
  already read 5 / 75 (their minimums) on butternut, so no GPU knobs; the dGPU
  stays as is.
- Defaults: bag CPU long-term cap 15 W, short-term 25 W; full profile
  `performance`; hot alert at 90 °C, 2 consecutive checks, 900 s cooldown.
- Built-in inputs by name regex, default
  `^(AT Translated Set 2 keyboard|Asus WMI hotkeys|.*Touchpad)$`.
- Display = any `card*-*` connector `connected` that doesn't match
  `eDP-* LVDS-* DSI-*`. AC = any `power_supply` of type `Mains` or `USB` with
  `online` = 1.
- Desk restores the RAPL values saved on the first bag apply (`$RUN/*.orig`).
- Every sysfs write: only when the value differs, logged, failure logged and
  ignored (exit 0). Missing paths are skipped.
- Override `$RUN/override` ∈ {bag, full}; anything else = auto. It sets the
  power tier only; the keyboard always follows the display.
- No `PREK_ALLOW_NO_CONFIG`, no `--no-verify`.

## Review Focus

- A USB keyboard plugged in at a headless desk must never be muted (test 2).
- Events during an apply must not leave a stale mode: udev uses
  `systemctl --no-block restart` (oneshot re-runs) rather than `start`.
- Apply twice in bag must not overwrite `*.orig` with the capped value (test 3b).
- A machine without RAPL/ASUS/thermal paths (other hosts, the check sandbox)
  must apply cleanly (test 7).
- Notification failure (no network in a bag) must not fail the unit or
  re-arm the cooldown wrongly (test 8: stub curl exit 1 → still exit 0).

---

### Task 1: Core script + flake check

**Files:**
- Create: `modules/nixos/features/headless-modes.sh`
- Create: `modules/nixos/features/headless-modes-test.sh`
- Create: `modules/nixos/features/headless-modes.nix` (check only in this task)

**Interfaces:**
- Produces: `headless-modes.sh <detect|apply|hot-check|set-override MODE|status>`.
  Env: `HM_SYS` (/sys), `HM_RUN` (/run/headless-mode), `HM_INPUT_REGEX`,
  `HM_IGNORE_CONNECTORS` (space-separated globs), `HM_BAG_LONG_W`,
  `HM_BAG_SHORT_W`, `HM_FULL_PROFILE`, `HM_PPD` (powerprofilesctl path or
  empty = skip), `HM_HOT_C`, `HM_HOT_COUNT`, `HM_HOT_COOLDOWN`,
  `HM_NTFY_TOPIC_FILE` (empty = journal only), `HM_CURL`, `HM_NOW` (test clock).
  `detect` prints `<desk|headless|bag> display=<0|1> ac=<0|1> override=<auto|bag|full>`.
- Produces: `perSystem.checks.headless-modes`.

- [ ] **Step 1: Write the test** (`headless-modes-test.sh`, run by
  `pkgs.runCommand` with bash/coreutils/gnugrep): builds `$T/sys` with
  `class/drm/card1-{eDP-1,HDMI-A-1}/status`, `class/power_supply/{ACAD,BAT1}`,
  `class/input/input{0,12,30}` (names: AT keyboard, `ASUP1205:00 093A:2003
  Touchpad`, `Logitech USB Keyboard`) each with `inhibited`=0,
  `class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw` (45000000,
  95000000), `class/thermal/thermal_zone3/{type=x86_pkg_temp,temp}`; stub
  `ppd` and `curl` append argv to `$T/calls`. Cases (assert files):
  1. HDMI connected, battery → `detect` = desk; inputs 0; RAPL unchanged; ppd `set performance`.
  2. HDMI off, AC → headless; input0/12 = 1, input30 = 0; RAPL unchanged.
  3. HDMI off, battery → bag; RAPL 15000000/25000000; ppd `set power-saver`; `.orig` = 45000000/95000000. 3b: apply again → `.orig` unchanged.
  4. AC back → headless; RAPL 45000000/95000000.
  5. only eDP connected → not a display.
  6. override full on battery headless → inputs 1, RAPL original; override bag on desk → inputs 0, RAPL capped; override `junk` → auto.
  7. empty sys tree (only drm) → `apply` exit 0.
  8. hot-check: temp 95000 ×2 → one curl call; again → none (cooldown, `HM_NOW` +60); `HM_NOW` +1000 ×2 → second call; temp 80000 resets the count; curl exit 1 → exit 0.
- [ ] **Step 2: Add the check to `headless-modes.nix`, run it, see it fail**
  Run: `nix build --no-link .#checks.x86_64-linux.headless-modes -L`
  Expected: FAIL (script missing / asserts).
- [ ] **Step 3: Implement `headless-modes.sh`** to the interface above
  (`set -u`, functions `display`, `on_ac`, `override`, `write_if_diff`, `save_orig`).
- [ ] **Step 4: Run the check** — Expected: PASS, all cases print `ok`.
- [ ] **Step 5: Commit** (`git add -N` the new files first; hook must run).

### Task 2: NixOS wiring + butternut

**Files:**
- Modify: `modules/nixos/features/headless-modes.nix` (module part)
- Modify: `modules/nixos/hosts/butternut/headless.nix` (import + enable)
- Drop: PR #7 commit `8a3db82` from the branch (`git rebase --onto main 8a3db82`)

**Interfaces:**
- Consumes: Task 1 script + env.
- Produces: `flake.nixosModules.headless-modes`, options
  `preferences.headlessModes.{enable, inputRegex, ignoreConnectors,
  bag.{longWatts,shortWatts}, fullProfile, powerKey.enable,
  hotAlert.{enable,celsius,topicFile}}` (topicFile default
  `preferences.agents.ntfy.topicFile or null`); package/command
  `headless-mode status|auto|bag|full|toggle` (toggle: bag ↔ auto; doas for
  root; notify-send when not on a TTY under Wayland); units
  `headless-mode-apply.service` (oneshot, after/wants ppd, wantedBy
  multi-user, `restartIfChanged = false`), `headless-mode-hot.{service,timer}`
  (30 s); udev `RUN+="systemctl --no-block restart headless-mode-apply.service"`
  on drm change HOTPLUG=1, power_supply change, input add; logind
  `HandlePowerKey=ignore`, `HandlePowerKeyLongPress=poweroff`; desktop item
  when `preferences.desktop.enable`.

- [ ] **Step 1:** rebase out `8a3db82`; write the module; enable on butternut.
- [ ] **Step 2: Verify** — `nix fmt`, `just check` (OK everywhere), unit
  file built: `nix build --no-link` of
  `nixosConfigurations.butternut.config.systemd.units."headless-mode-apply.service".unit`,
  `headless-mode status` run from the built package on butternut prints a mode
  matching reality (monitor attached → desk).
- [ ] **Step 3: Commit**, then `agent-push --force-with-lease`, retitle PR #7
  with `Affects:` from `nix run .#fleet -- affects`, and the on-device check
  list (below) in the PR body.

On-device check list (user, after deploy): `headless-mode status`;
unplug monitor → `journalctl -u headless-mode-apply -n 20` shows inputs muted;
unplug AC → RAPL `cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw`
= 15000000 and `powerprofilesctl get` = power-saver; press power once → stays up.
