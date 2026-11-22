"""battery-alert: tiered low-battery alerts for the desktop session.

Watches this machine's battery (sysfs, woken by udev power_supply events) or,
with a `remote` config, another host's battery over HTTP (`serve` there):
hazel tracks a headless butternut at the café. Each tier fires once per
discharge, highest first (booting at 5 % does not replay the 20 % and 10 %
alerts):

  low       a normal notification with the time left
  warning   a critical (sticky) notification, a soft chime at the current
            volume, a KDE Connect ping to the phone
  critical  a persistent overlay (click-through, live % and time left) and a
            distinct alarm on the built-in speakers at a fixed volume (the
            sink is unmuted and raised for the alarm, then restored), repeated
            every `alarm_interval` s; another phone ping

Plugging in closes the overlay at once and replaces the warning with a short
"Charging" notification (plus a rising chime after warning/critical). The
tiers re-arm after 30 s on AC, so a loose cable does not replay everything.
A remote host that drops off the network while on battery gets one
"unreachable" notification (it may have shut down).

  battery-alert --config FILE              run the daemon (systemd user service)
  battery-alert mute [--instance NAME]     silence the alarm of this discharge
  battery-alert status                     print this battery as JSON
  battery-alert serve --config FILE        answer one HTTP request with the
                                           status (systemd socket, Accept=yes)
  battery-alert bar --instance NAME        waybar JSON for a watched remote
"""

import argparse
import json
import os
import select
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

PS = Path("/sys/class/power_supply")
BASE = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "battery-alert"
REARM_AFTER = 30  # s on AC before the tiers fire again
LOST_AFTER = 3  # failed remote polls before "unreachable"
LAPTOP = "\U000f0322"  # nf-md-laptop


def read(p, name):
    try:
        return (p / name).read_text().strip()
    except OSError:
        return None


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def snapshot():
    """{pct, minutes, on_battery} or None without a system battery."""
    bats, ac = [], None
    for p in sorted(PS.glob("*")):
        kind = read(p, "type")
        if kind == "Battery" and read(p, "scope") != "Device" and read(p, "present") != "0":
            bats.append(p)
        elif kind in ("Mains", "USB") and read(p, "online") is not None:
            ac = bool(ac) or read(p, "online") == "1"
    if not bats:
        return None
    now = full = rate = 0.0
    caps, discharging = [], False
    for b in bats:
        n, f, r = (num(read(b, "energy_now")), num(read(b, "energy_full")),
                   num(read(b, "power_now")))
        if n is None:  # charge-based firmware: µAh / µA, same ratio
            n, f, r = (num(read(b, "charge_now")), num(read(b, "charge_full")),
                       num(read(b, "current_now")))
        if n is not None and f:
            now, full, rate = now + n, full + f, rate + abs(r or 0)
        cap = num(read(b, "capacity"))
        if cap is not None:
            caps.append(cap)
        discharging = discharging or read(b, "status") == "Discharging"
    pct = round(100 * now / full) if full else round(sum(caps) / len(caps)) if caps else None
    if pct is None:
        return None
    on_battery = (not ac) if ac is not None else discharging
    minutes = int(60 * now / rate) if on_battery and rate > 0 and now else None
    return {"pct": max(0, min(100, pct)), "minutes": minutes, "on_battery": on_battery}


class Remote:
    """Another host's `serve` endpoint; the first URL that answers is kept
    first (cable before tailnet)."""

    def __init__(self, urls):
        self.urls = list(urls)

    def __call__(self):
        for i, url in enumerate(self.urls):
            try:
                with urllib.request.urlopen(url, timeout=4) as r:
                    s = json.load(r)
            except (OSError, ValueError):
                continue
            if i:
                self.urls.insert(0, self.urls.pop(i))
            return s if isinstance(s, dict) and "pct" in s else None
        return None


def left_text(minutes):
    if minutes is None:
        return ""
    h, m = divmod(minutes, 60)
    return f"about {h} h {m:02d} min left" if h else f"about {m} min left"


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def session_env():
    """The session environment as systemd has it now: the service may have
    started before sway exported WAYLAND_DISPLAY."""
    env = dict(os.environ)
    for line in run(["systemctl", "--user", "show-environment"]).splitlines():
        k, _, v = line.partition("=")
        if k in ("WAYLAND_DISPLAY", "DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"):
            env[k] = v
    return env


def phone(msg):
    for dev in run(["kdeconnect-cli", "--list-available", "--id-only"]).split():
        run(["kdeconnect-cli", "--ping-msg", msg, "-d", dev])


def speaker():
    """(node id, node name) of the built-in analog sink, or None. Skips HDMI
    and Bluetooth: the alarm is for whoever is near the laptop."""
    try:
        objs = json.loads(run(["pw-dump"]) or "[]")
    except ValueError:
        return None
    for o in objs:
        props = (o.get("info") or {}).get("props") or {}
        name = props.get("node.name", "")
        builtin = name.startswith("alsa_output.pci") and "hdmi" not in name.lower()
        if props.get("media.class") == "Audio/Sink" and builtin:
            return str(o["id"]), name
    return None


def play(path, volume=None):
    """Play a sound; with `volume`, on the built-in speakers at that sink
    volume (unmuted), restoring the user's level and mute afterwards."""
    if volume is None:
        run(["pw-play", path])
        return
    sp = speaker()
    target = sp[0] if sp else "@DEFAULT_AUDIO_SINK@"
    before = run(["wpctl", "get-volume", target]).split()
    try:
        run(["wpctl", "set-mute", target, "0"])
        run(["wpctl", "set-volume", target, f"{volume:.2f}"])
        run(["pw-play", *(["--target", sp[1]] if sp else []), path], timeout=20)
    finally:
        if len(before) >= 2:
            run(["wpctl", "set-volume", target, before[1]])
            run(["wpctl", "set-mute", target, "1" if "[MUTED]" in before else "0"])


class Overlay:
    def __init__(self, cmd):
        self.cmd, self.proc, self.next_try = cmd, None, 0.0

    def show(self, msg):
        if self.proc is None or self.proc.poll() is not None:
            if time.monotonic() < self.next_try:
                return
            self.next_try = time.monotonic() + 30
            try:
                self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, env=session_env())
            except OSError as err:
                print(f"battery-alert: overlay: {err}", file=sys.stderr)
                self.proc = None
                return
        try:
            self.proc.stdin.write((json.dumps(msg) + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            self.proc = None

    def close(self):
        if self.proc is not None:
            try:
                self.proc.stdin.close()
                self.proc.wait(timeout=3)
            except (OSError, subprocess.SubprocessError):
                self.proc.kill()
            self.proc = None


class Waker:
    """Sleeps until a power_supply uevent or the timeout (local battery)."""

    def __init__(self, local):
        self.proc = None
        if local:
            try:
                self.proc = subprocess.Popen(
                    ["udevadm", "monitor", "--udev", "--subsystem-match=power_supply"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            except OSError:
                pass

    def wait(self, timeout):
        if self.proc is None or self.proc.poll() is not None:
            time.sleep(timeout)
            return
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if ready:
            os.read(self.proc.stdout.fileno(), 65536)
            time.sleep(0.5)  # let the other supply (AC/battery) update too


def daemon(cfg):
    remote = cfg.get("remote")
    instance = remote["name"] if remote else "local"
    rundir = BASE / instance
    rundir.mkdir(parents=True, exist_ok=True)
    mute, state_file = rundir / "mute", rundir / "state.json"
    source = Remote(remote["urls"]) if remote else snapshot
    # Titles: "Battery low" here, "Butternut battery low" for a remote.
    who = f"{remote['label']} battery" if remote else "Battery"
    host = remote["label"] if remote else cfg["host"]
    tag = ["-h", f"string:x-canonical-private-synchronous:battery-{instance}",
           "-h", f"string:x-dunst-stack-tag:battery-{instance}"]
    tiers = [("critical", cfg["critical"]), ("warning", cfg["warning"]), ("low", cfg["low"])]
    order = [name for name, _ in reversed(tiers)]  # low, warning, critical
    overlay = Overlay(cfg["overlay"])
    waker = Waker(local=not remote)
    fired, ac_since, last_alarm = set(), None, 0.0
    last, failures, lost_since, lost_notified, published = None, 0, None, False, None
    state_file.unlink(missing_ok=True)  # stale from an earlier run

    def notify(urgency, title, body, icon, expire=None):
        cmd = ["notify-send", "-a", "Battery", "-u", urgency, "-i", icon, *tag]
        if expire is not None:
            cmd += ["-t", str(expire)]
        run(cmd + [title, body])

    def publish(state):
        # For the bar (remote instances): rewrite + nudge waybar on change.
        nonlocal published
        if state == published:
            return
        published = state
        tmp = state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(state_file)
        if cfg.get("bar_signal"):
            run(["systemctl", "--user", "kill", "--kill-whom=main",
                 "-s", f"SIGRTMIN+{cfg['bar_signal']}", "waybar.service"])

    while True:
        s = source()
        now = time.monotonic()
        if s is None:
            failures += 1
            if remote and last and failures >= LOST_AFTER:
                lost_since = lost_since or int(time.time())
                publish({"reachable": False, "last": last, "since": lost_since})
                if last["on_battery"] and not lost_notified:
                    overlay.close()
                    urgency = "critical" if fired & {"warning", "critical"} else "normal"
                    notify(urgency, f"{host} unreachable",
                           f"Last seen at {last['pct']}% on battery. It may have shut down.",
                           "battery-missing")
                lost_notified = True
            waker.wait(300 if not remote else 30)
            continue
        failures, lost_since, lost_notified, last = 0, None, False, s
        pct, left = s["pct"], left_text(s.get("minutes"))
        shutdown = s.get("shutdown", cfg["shutdown"]) if remote else cfg["shutdown"]

        if s["on_battery"]:
            ac_since = None
            reached = next((n for n, t in tiers if pct <= t), None)
            if reached and reached not in fired:
                fired.update(order[:order.index(reached) + 1])
                body = left.capitalize() + "." if left else ""
                if reached == "low":
                    notify("normal", f"{who} low · {pct}%", body, "battery-low")
                elif reached == "warning":
                    notify("critical", f"{who} very low · {pct}%",
                           f"{body} Plug in soon.".strip(), "battery-caution")
                    play(cfg["sounds"]["warning"])
                    if cfg["phone"]:
                        phone(f"{host}: battery {pct}%, plug it in soon")
                else:
                    notify("critical", f"{who} critical · {pct}%",
                           f"{body} {shutdown}".strip(), "battery-caution")
                    if cfg["phone"]:
                        phone(f"{host}: battery critical, {pct}%. Plug it in now")
                    mute.unlink(missing_ok=True)  # a stray earlier click
                    last_alarm = 0.0
            if "critical" in fired:
                muted = mute.exists()
                overlay.show({"pct": pct, "left": left, "muted": muted,
                              "title": f"Plug in {host}" if remote else "Plug in the charger",
                              "shutdown": shutdown})
                if not muted and now - last_alarm >= cfg["alarm_interval"]:
                    play(cfg["sounds"]["alarm"], cfg["alarm_volume"])
                    last_alarm = time.monotonic()
        else:
            if ac_since is None:
                ac_since = now
                if fired:
                    overlay.close()
                    notify("low", f"{host + ' charging' if remote else 'Charging'} · {pct}%",
                           left.capitalize(), "battery-good-charging", 4000)
                    if fired & {"warning", "critical"}:
                        play(cfg["sounds"]["plugged"])
            if fired and now - ac_since >= REARM_AFTER:
                fired.clear()
                mute.unlink(missing_ok=True)

        tier = next((n for n in ("critical", "warning", "low") if n in fired), "")
        publish({"reachable": True, "pct": pct, "minutes": s.get("minutes"),
                 "on_battery": s["on_battery"], "tier": tier if s["on_battery"] else ""})

        if "critical" in fired and s["on_battery"]:
            timeout = 2 if not remote else 10
        elif fired or pct <= cfg["low"] + 5:
            timeout = 15 if not remote else 30
        else:
            timeout = 120 if not remote else 60
        waker.wait(timeout)


def serve(cfg):
    """One HTTP/1.0 exchange on stdin/stdout (systemd socket, Accept=yes):
    whatever the request, answer with the status JSON."""
    inp = sys.stdin.buffer
    for _ in range(50):  # request line + headers, until the blank line
        line = inp.readline(4096)
        if not line or line in (b"\r\n", b"\n"):
            break
    s = snapshot()
    body = json.dumps(dict(s, host=cfg["host"], shutdown=cfg["shutdown"]) if s else {}).encode()
    status = "200 OK" if s else "404 Not Found"
    head = (f"HTTP/1.0 {status}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n")
    sys.stdout.buffer.write(head.encode() + body)
    sys.stdout.buffer.flush()


def bar(instance, label, caption):
    """waybar JSON for a watched remote: hidden while unknown, a faint laptop
    on AC, laptop + percent on battery (tier class), "?" once lost while on
    battery."""
    try:
        st = json.loads((BASE / instance / "state.json").read_text())
    except (OSError, ValueError):
        st = {}

    def out(text, tooltip, *cls):
        print(json.dumps({"text": text, "tooltip": tooltip, "class": list(cls), "alt": cls[-1]},
                         ensure_ascii=False))

    def value(v):
        # caption is in CSS px; Pango sizes are 1024ths of a pt (1 px = 0.75 pt).
        return f"{LAPTOP}\n<span size='{caption * 768}'>{v}</span>"

    if not st:
        return out("", "", "none")
    if not st.get("reachable"):
        last = st.get("last") or {}
        if not last.get("on_battery"):
            return out("", "", "none")
        since = time.strftime("%H:%M", time.localtime(st["since"])) if st.get("since") else "?"
        return out(value("?"), f"{label} unreachable since {since}\nLast seen at {last.get('pct')}% on battery", "lost")
    pct, left = st["pct"], left_text(st.get("minutes"))
    if not st["on_battery"]:
        return out(LAPTOP, f"{label} · on AC · {pct}%", "ac")
    tip = f"{label} on battery · {pct}%" + (f"\n{left.capitalize()}" if left else "")
    return out(value(pct), tip, "discharging", *([st["tier"]] if st.get("tier") else []))


def main():
    ap = argparse.ArgumentParser(prog="battery-alert")
    ap.add_argument("command", nargs="?", choices=["mute", "status", "serve", "bar"])
    ap.add_argument("--config")
    ap.add_argument("--instance", default="local")
    ap.add_argument("--label", default="")
    ap.add_argument("--caption", type=int, default=11)
    args = ap.parse_args()
    if args.command == "mute":
        (BASE / args.instance).mkdir(parents=True, exist_ok=True)
        (BASE / args.instance / "mute").touch()
        return
    if args.command == "status":
        print(json.dumps(snapshot()))
        return
    if args.command == "bar":
        bar(args.instance, args.label or args.instance.capitalize(), args.caption)
        return
    if not args.config:
        sys.exit("battery-alert: --config is required")
    with open(args.config) as f:
        cfg = json.load(f)
    if args.command == "serve":
        serve(cfg)
    else:
        daemon(cfg)


if __name__ == "__main__":
    main()
