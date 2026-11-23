"""dictate-overlay: live feedback for a dictation session (GTK4, layer shell).

A small opaque panel at the top right, next to the vertical bar: a dot and a
running timer (mm:ss; warning colour past --long-session-sec, with a note
that it is a good moment to stop), the input level and the mic it records
from (with a warning when that mic sends only silence), language and backend,
the last committed text (stream mode) or the draft's progress (batch mode),
and the transcription progress after stop. It never takes keyboard focus and
lets pointer input through, so wtype keeps typing into the focused window.

Input: one JSON object per line on stdin, sent by dictate-stream ~15 times a
second ({t, level, speech, lang, mode, backend, input, warning, lines, done,
total, failed, state}); EOF
closes it. Look: the palette CSS rendered per mode by the dictation feature
(--css, from the theme state dir); every colour and size lives there.

  --demo [--demo-mode batch|stream] [--demo-t SEC]
                            render sample content (tests)
"""

import argparse
import json
import sys
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
try:
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell as LayerShell
except (ValueError, ImportError):
    LayerShell = None
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

DEMO = {
    "t": 754.0, "level": 0.62, "speech": True, "lang": "EN",
    "backend": "butternut GPU", "input": "soundcore P40i", "warning": "",
    "mode": "batch", "done": 3, "total": 4,
    "failed": 0, "state": "recording",
    "lines": ["Ask not what your country can do for you.",
              "Ask what you can do for your country.",
              "And so, my fellow Americans, the segment that is being "
              "typed right now wraps onto a second line."],
}


def fmt(t):
    m, s = divmod(int(max(t, 0)), 60)
    return f"{m:02d}:{s:02d}"


def joined(lines):
    out = ""
    for t in lines:
        out += t if not out or t[:1] in ".,;:!?…،؛؟" else " " + t
    return out


class Overlay:
    def __init__(self, app, args):
        self.args = args
        self.t_base, self.t_mono = 0.0, time.monotonic()
        self.state = "recording"
        self.minute = 0
        self.cue_until = 0.0
        self.level = 0.0

        css = Gtk.CssProvider()
        try:
            css.load_from_path(args.css)
        except GLib.Error as err:
            print(f"dictate-overlay: {err}", file=sys.stderr)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER)

        win = self.win = Gtk.Window(application=app, title="Dictation")
        win.add_css_class("dictation")
        win.set_decorated(False)
        win.set_resizable(False)
        win.set_focusable(False)
        win.set_can_focus(False)
        if LayerShell and LayerShell.is_supported():
            LayerShell.init_for_window(win)
            LayerShell.set_namespace(win, "dictation")
            LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
            LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
            for edge in (LayerShell.Edge.TOP, LayerShell.Edge.RIGHT):
                LayerShell.set_anchor(win, edge, True)
                LayerShell.set_margin(win, edge, args.margin)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.add_css_class("panel")
        root.set_size_request(args.width, -1)
        win.set_child(root)

        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        head.add_css_class("head")
        self.dot = Gtk.Label(label="●")
        self.dot.add_css_class("dot")
        self.timer = Gtk.Label(label="00:00")
        self.timer.add_css_class("timer")
        self.meta = Gtk.Label(label="", xalign=1, hexpand=True)
        self.meta.add_css_class("meta")
        for w in (self.dot, self.timer, self.meta):
            head.append(w)
        root.append(head)

        self.meter = Gtk.LevelBar(min_value=0, max_value=1, value=0)
        for name in ("low", "high", "full"):
            self.meter.remove_offset_value(name)
        self.meter.add_css_class("meter")
        root.append(self.meter)

        width_chars = max(20, args.width // 7)
        self.mic = self.label("meta", lines=1, chars=width_chars)
        self.mic.set_ellipsize(3)  # Pango.EllipsizeMode.END
        root.append(self.mic)
        self.older = self.label("older", lines=1, chars=width_chars)
        self.latest = self.label("latest", lines=3, chars=width_chars)
        self.status = self.label("status", lines=1, chars=width_chars)
        self.note = self.label("note", lines=2, chars=width_chars)
        self.note.set_ellipsize(0)
        mins = int(args.long_session_sec // 60)
        self.note.set_text(f"Past {mins} min: a good moment to stop. "
                           "Everything so far is saved in the draft.")
        self.note.set_visible(False)
        for w in (self.older, self.latest, self.status, self.note):
            root.append(w)

        win.connect("realize", self.on_realize)
        win.present()
        GLib.timeout_add(250, self.tick)

    def label(self, cls, lines, chars):
        lab = Gtk.Label(xalign=0, wrap=True, lines=lines, max_width_chars=chars,
                        width_chars=chars)
        lab.set_wrap_mode(2)  # Pango.WrapMode.WORD_CHAR
        lab.set_ellipsize(1)  # Pango.EllipsizeMode.START: keep the newest words
        lab.add_css_class(cls)
        lab.set_visible(False)
        return lab

    def on_realize(self, win):
        # Pointer input passes through (an empty input region).
        try:
            import cairo
            win.get_surface().set_input_region(cairo.Region())
        except (ImportError, AttributeError, TypeError):
            pass

    def update(self, msg):
        self.t_base, self.t_mono = msg.get("t", 0.0), time.monotonic()
        self.state = msg.get("state", "recording")
        # Fast attack, slow release: a calm meter.
        lv = float(msg.get("level", 0.0))
        self.level = lv if lv > self.level else self.level * 0.7 + lv * 0.3
        self.meter.set_value(self.level)
        self.meta.set_text(f"{msg.get('lang', '')} · {msg.get('backend', '')}")
        self.mic.set_text(f"Mic: {msg.get('input', '')}")
        self.mic.set_visible(bool(msg.get("input")))
        lines = msg.get("lines") or []
        self.older.set_text(joined(lines[:-1]))
        self.older.set_visible(len(lines) > 1)
        self.latest.set_text(lines[-1] if lines else "")
        self.latest.set_visible(bool(lines))
        done, total = int(msg.get("done", 0)), int(msg.get("total", 0))
        failed = int(msg.get("failed", 0))
        finishing = self.state in ("finishing", "typing")
        batch = msg.get("mode") == "batch"
        if self.state == "typing":
            status = "Pasting…" if batch else "Typing…"
        elif msg.get("warning") and self.state == "recording":
            status = msg["warning"]
        elif finishing and done < total:
            status = f"Transcribing {done + 1}/{total} segments…"
        elif finishing:
            status = "Finishing…"
        elif batch:
            status = ("Recording to a draft; the text is pasted when you stop."
                      if not total else
                      f"Draft saved · {done} of {total} segments transcribed")
        elif done < total:
            status = "Transcribing…"
        elif not lines:
            status = "Speak; text is typed at each pause."
        else:
            status = ""
        if failed:
            status += f" ({failed} failed, kept in the draft)"
        self.status.set_text(status)
        self.status.set_visible(bool(status))
        for w, cls in ((self.dot, "finishing"), (self.timer, "finishing")):
            (w.add_css_class if finishing else w.remove_css_class)(cls)
        self.tick()
        return False

    def elapsed(self):
        if self.state == "finishing":
            return self.t_base
        return self.t_base + time.monotonic() - self.t_mono

    def tick(self):
        t = self.elapsed()
        self.timer.set_text(fmt(t))
        now = time.monotonic()
        m = int(t // 60)
        if m > self.minute:
            self.minute = m
            self.cue_until = now + 2.0
        cue = now < self.cue_until
        (self.timer.add_css_class if cue else self.timer.remove_css_class)("minute")
        long = t >= self.args.long_session_sec
        (self.timer.add_css_class if long else self.timer.remove_css_class)("long")
        self.note.set_visible(long and self.state == "recording")
        return True


def main():
    ap = argparse.ArgumentParser(prog="dictate-overlay")
    ap.add_argument("--css", default="")
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--margin", type=int, default=8)
    ap.add_argument("--long-session-sec", type=float, default=600)
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--demo-mode", default="batch")
    ap.add_argument("--demo-t", type=float, default=DEMO["t"])
    args = ap.parse_args()

    app = Gtk.Application(application_id=None)

    def reader(ov):
        for line in sys.stdin.buffer:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            GLib.idle_add(ov.update, msg)
        GLib.idle_add(app.quit)

    def activate(app):
        if Gdk.Display.get_default() is None:
            sys.exit("dictate-overlay: no display")
        app.hold()
        ov = Overlay(app, args)
        if args.demo:
            demo = dict(DEMO, mode=args.demo_mode, t=args.demo_t)
            if args.demo_mode == "batch":
                demo["lines"] = []
            ov.update(demo)
        else:
            threading.Thread(target=reader, args=(ov,), daemon=True).start()

    app.connect("activate", activate)
    app.run([])


if __name__ == "__main__":
    main()
