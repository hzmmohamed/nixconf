"""Wallpaper palette generator (preferences.theme.source = "wallpaper").

Builds one mode's palette (same keys as modules/theme.nix mkPalette) from
matugen's JSON dump and renders the per-app palette files from templates.

Resolution chain, per key: pinned -> wallpaper (matugen) -> Catppuccin
fallback, so a missing role falls through instead of rendering black.

Templates are the Nix renderers (preferences.theme.files) applied to a
placeholder palette: every colour is "@@THEME:<key>@@" (or
"@@THEME_NOHASH:<key>@@" for palette.noHash.<key>). One source of truth.

A WCAG contrast guard nudges failing text/background pairs to >= 4.5:1 and
falls back to the Catppuccin value when nudging can't get there.
"""

import argparse
import json
import math
import os
import re
import sys

MIN_CONTRAST = 4.5

# Text tiers on `surface` (design targets).
TIERS = {"fgDim": 9.0, "fgMuted": 6.6, "fgFaint": 4.6}

# Catppuccin accents: harmonised towards the wallpaper's source colour.
ACCENTS = [
    "rosewater", "flamingo", "pink", "mauve", "red", "maroon", "peach",
    "yellow", "green", "teal", "sky", "sapphire", "blue", "lavender",
]

# (foreground, background) pairs that carry text.
TEXT_PAIRS = (
    [("fg", "surface"), ("text", "base"), ("subtext1", "base"),
     ("subtext0", "base"), ("onSurface", "surface"),
     ("onSurfaceVariant", "surface"), ("fg", "surfaceContainerLow"),
     ("fg", "surfaceContainer"), ("fg", "surfaceContainerHigh"),
     ("onAccent", "accent"), ("onInverseSurface", "inverseSurface")]
    + [(k, "surface") for k in TIERS]
    + [(k, "surface") for k in ACCENTS + ["error"]]
)

HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
TOKEN = re.compile(r"@@THEME(_NOHASH)?:([A-Za-z0-9_]+)@@")


# --- colour maths (sRGB, opaque) --------------------------------------------
def to_rgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def to_hex(rgb):
    return "#" + "".join(
        "%02x" % max(0, min(255, int(round(c)))) for c in rgb)


def mix(a, b, t):
    """t*a + (1-t)*b, like modules/theme.nix `mix`."""
    return to_hex([t * x + (1 - t) * y for x, y in zip(to_rgb(a), to_rgb(b))])


def _lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _delin(c):
    c = c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return c * 255.0


def luminance(h):
    r, g, b = (_lin(c) for c in to_rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def to_oklch(h):
    r, g, b = (_lin(c) for c in to_rgb(h))
    l_ = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m_ = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s_ = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return L, math.hypot(A, B), math.degrees(math.atan2(B, A)) % 360


def from_oklch(L, C, H):
    A, B = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l_ = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m_ = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s_ = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    r = 4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_
    g = -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_
    b = -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_
    return to_hex([_delin(max(0.0, min(1.0, c))) for c in (r, g, b)])


def harmonize(colour, source):
    """Rotate colour's hue towards source by min(diff/2, 15deg) (Material)."""
    L, C, H = to_oklch(colour)
    _, _, Hs = to_oklch(source)
    diff = (Hs - H + 180) % 360 - 180
    return from_oklch(L, C, H + math.copysign(min(abs(diff) * 0.5, 15), diff))


def nudge(fg, bg, target):
    """Move fg away from bg (towards black/white) until contrast >= target."""
    if contrast(fg, bg) >= target:
        return fg
    pole = "#000000" if luminance(bg) > 0.18 else "#ffffff"
    for i in range(1, 21):
        cand = mix(pole, fg, i / 20)
        if contrast(cand, bg) >= target:
            return cand
    return None


def tier(fg, bg, target):
    """Colour between fg and bg with contrast ~target (never above fg's)."""
    if contrast(fg, bg) <= target:
        return fg
    lo, hi = 0.0, 1.0  # weight of fg
    for _ in range(24):
        mid = (lo + hi) / 2
        if contrast(mix(fg, bg, mid), bg) >= target:
            hi = mid
        else:
            lo = mid
    return mix(fg, bg, hi)


# --- palette ----------------------------------------------------------------
def matugen_roles(path, mode):
    try:
        with open(path) as f:
            colours = json.load(f)["colors"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("theme-palette: no usable matugen output (%s); "
              "using the Catppuccin fallback" % e, file=sys.stderr)
        return {}
    roles = {}
    for name, v in colours.items():
        try:
            c = (v.get(mode) or v["default"])["color"]
        except (AttributeError, KeyError, TypeError):
            continue
        if isinstance(c, str) and HEX.match(c):
            roles[name] = c.lower()
    return roles


def wallpaper_palette(r, fallback):
    """Map Material roles onto the palette shape; omit what's missing."""
    need = ["surface", "on_surface", "on_surface_variant", "outline",
            "outline_variant", "primary", "on_primary"]
    if any(k not in r for k in need):
        return {}
    p = {
        "base": r["surface"],
        "mantle": r.get("surface_container_low"),
        "crust": r.get("surface_container_lowest"),
        "surface0": r.get("surface_container"),
        "surface1": r.get("surface_container_high"),
        "surface2": r.get("surface_container_highest"),
        "overlay0": r["outline_variant"],
        "overlay1": mix(r["outline"], r["outline_variant"], 0.5),
        "overlay2": r["outline"],
        "subtext0": r["on_surface_variant"],
        "subtext1": mix(r["on_surface"], r["on_surface_variant"], 0.5),
        "text": r["on_surface"],
        "accent": r["primary"],
        "primary": r["primary"],
        "onAccent": r["on_primary"],
        "error": r.get("error"),
        "surface": r["surface"],
        "surfaceContainerLow": r.get("surface_container_low"),
        "surfaceContainer": r.get("surface_container"),
        "surfaceContainerHigh": r.get("surface_container_high"),
        "onSurface": r["on_surface"],
        "onSurfaceVariant": r["on_surface_variant"],
        "outline": r["outline"],
        "outlineVariant": r["outline_variant"],
        "inverseSurface": r.get("inverse_surface"),
        "onInverseSurface": r.get("inverse_on_surface"),
    }
    source = r.get("source_color", r["primary"])
    for name in ACCENTS:
        if HEX.match(str(fallback.get(name, ""))):
            p[name] = harmonize(fallback[name], source)
    # The accent slot itself is the wallpaper's primary.
    p[fallback.get("accentName") or "lavender"] = r["primary"]
    return {k: v for k, v in p.items() if v}


def guard(p, fallback):
    for fg, bg in TEXT_PAIRS:
        if fg not in p or bg not in p:
            continue
        fixed = nudge(p[fg], p[bg], MIN_CONTRAST)
        if fixed is None:
            fixed = fallback.get(fg, p[fg])
            print("theme-palette: %s on %s fails %.1f:1; using fallback"
                  % (fg, bg, MIN_CONTRAST), file=sys.stderr)
        p[fg] = fixed


def derive(p):
    p["fg"] = p["text"]
    for k, target in TIERS.items():
        p[k] = tier(p["text"], p["base"], target)
    for name, t in (("hairlineSoft", 0.13), ("hairline", 0.26),
                    ("hairlineStrong", 0.42), ("tint5", 0.05),
                    ("tint10", 0.10), ("tint16", 0.16)):
        p[name] = mix(p["text"], p["base"], t)


def build(matugen, mode, fallback, pinned):
    wall = wallpaper_palette(matugen_roles(matugen, mode), fallback)
    p = {k: v for k, v in fallback.items() if isinstance(v, str)}
    if wall:
        p.update(wall)
        guard(p, fallback)  # base text first, so tiers/mixes derive from it
        derive(p)
        guard(p, fallback)
    p.update({k: v.lower() for k, v in pinned.items()
              if isinstance(v, str) and HEX.match(v)})
    return p


def render(templates, out, palette, fallback):
    os.makedirs(out, exist_ok=True)

    def sub(m):
        key = m.group(2)
        v = palette.get(key, fallback.get(key))
        if not isinstance(v, str):
            print("theme-palette: unknown key %r" % key, file=sys.stderr)
            return m.group(0)
        return v.lstrip("#") if m.group(1) else v

    for name in sorted(os.listdir(templates)):
        with open(os.path.join(templates, name)) as f:
            text = f.read()
        with open(os.path.join(out, name), "w") as f:
            f.write(TOKEN.sub(sub, text))
    with open(os.path.join(out, "palette.json"), "w") as f:
        json.dump(palette, f, indent=2, sort_keys=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--matugen", required=True, help="matugen --json hex dump")
    ap.add_argument("--mode", required=True, choices=["light", "dark"])
    ap.add_argument("--fallback", required=True, help="Catppuccin palette JSON")
    ap.add_argument("--pinned", help='JSON {"light": {...}, "dark": {...}}')
    ap.add_argument("--templates", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    with open(a.fallback) as f:
        fallback = json.load(f)
    pinned = {}
    if a.pinned and os.path.exists(a.pinned):
        try:
            with open(a.pinned) as f:
                pinned = json.load(f).get(a.mode) or {}
        except (OSError, ValueError, AttributeError) as e:
            print("theme-palette: ignoring %s (%s)" % (a.pinned, e),
                  file=sys.stderr)
    palette = build(a.matugen, a.mode, fallback, pinned)
    render(a.templates, a.out, palette, fallback)


if __name__ == "__main__":
    main()
