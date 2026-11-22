"""battery-overlay: the persistent critical-battery panel (GTK4, layer shell).

Top centre, on the overlay layer (above fullscreen video), never takes
keyboard focus and lets pointer input through: it stays in sight until the
charger is plugged in but never blocks work. A battery glyph and the
percentage in the error colour, the time left, and what happens next.

Input: one JSON object per line on stdin from battery-alert
({pct, left, muted, title, shutdown}); EOF closes it. Look: the palette CSS rendered per mode
by the battery-notify feature (--css); every colour and size lives there.

  --demo    render sample content (tests)
"""

import argparse
import json
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
try:
    gi.require_version("Gtk4LayerShell", "1.0")
    from gi.repository import Gtk4LayerShell as LayerShell
except (ValueError, ImportError):
    LayerShell = None
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

GLYPHS = ["󰂎", "󰁺", "󰁻"]  # empty, 10 %, 20 %


class Overlay:
    def __init__(self, app, args):
        self.args = args
        css = Gtk.CssProvider()
        try:
            css.load_from_path(args.css)
        except GLib.Error as err:
            print(f"battery-overlay: {err}", file=sys.stderr)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_USER)

        win = self.win = Gtk.Window(application=app, title="Battery critical")
        win.add_css_class("battery-alert")
        win.set_decorated(False)
        win.set_resizable(False)
        win.set_focusable(False)
        win.set_can_focus(False)
        if LayerShell and LayerShell.is_supported():
            LayerShell.init_for_window(win)
            LayerShell.set_namespace(win, "battery-alert")
            LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
            LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
            LayerShell.set_anchor(win, LayerShell.Edge.TOP, True)
            LayerShell.set_margin(win, LayerShell.Edge.TOP, args.margin)

        root = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        root.add_css_class("panel")
        root.set_size_request(args.width, -1)
        win.set_child(root)

        self.glyph = Gtk.Label(label=GLYPHS[0])
        self.glyph.add_css_class("glyph")
        self.pct = Gtk.Label(label="")
        self.pct.add_css_class("pct")
        root.append(self.glyph)
        root.append(self.pct)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True)
        text.add_css_class("text")
        text.set_valign(Gtk.Align.CENTER)
        self.title = Gtk.Label(xalign=0, label="Plug in the charger")
        self.title.add_css_class("title")
        self.left = Gtk.Label(xalign=0)
        self.left.add_css_class("left")
        self.note = Gtk.Label(xalign=0, wrap=True, max_width_chars=40)
        self.note.add_css_class("note")
        for w in (self.title, self.left, self.note):
            text.append(w)
        root.append(text)

        win.connect("realize", self.on_realize)
        win.present()

    def on_realize(self, win):
        # Pointer input passes through (an empty input region).
        try:
            import cairo
            win.get_surface().set_input_region(cairo.Region())
        except (ImportError, AttributeError, TypeError):
            pass

    def update(self, msg):
        pct = int(msg.get("pct", 0))
        self.glyph.set_text(GLYPHS[min(pct // 10, 2)])
        self.pct.set_text(f"{pct}%")
        self.title.set_text(msg.get("title") or "Plug in the charger")
        left = msg.get("left") or ""
        self.left.set_text(left.capitalize())
        self.left.set_visible(bool(left))
        hint = "Alarm silenced." if msg.get("muted") else self.args.mute_hint
        self.note.set_text(" ".join(s for s in (msg.get("shutdown"), hint) if s))
        return False


def main():
    ap = argparse.ArgumentParser(prog="battery-overlay")
    ap.add_argument("--css", default="")
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--margin", type=int, default=24)
    ap.add_argument("--mute-hint", default="")
    ap.add_argument("--demo", action="store_true")
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
            sys.exit("battery-overlay: no display")
        app.hold()
        ov = Overlay(app, args)
        if args.demo:
            ov.update({"pct": 6, "left": "about 11 min left", "muted": False,
                       "shutdown": "Hazel shuts down at 2%."})
        else:
            threading.Thread(target=reader, args=(ov,), daemon=True).start()

    app.connect("activate", activate)
    app.run([])


if __name__ == "__main__":
    main()
