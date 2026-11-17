"""Wallpaper palette generator (preferences.theme.source = "wallpaper").

Builds one mode's palette (same keys as modules/theme.nix mkPalette) from
matugen's JSON dump and renders the per-app palette files from templates.

Resolution chain, per key: pinned -> wallpaper (matugen) -> Catppuccin
fallback, so a missing role falls through instead of rendering black.

Templates are the Nix renderers (preferences.theme.files) applied to a
placeholder palette: every colour is "@@THEME:<key>@@" (or
"@@THEME_NOHASH:<key>@@" for palette.noHash.<key>). One source of truth.

Contrast contract (docs/plans/2026-11-17-design-system.md, section 2): every
(role, surface) pair in CONTRACT is guaranteed its minimum WCAG 2.2 ratio.
Failing roles are stepped in OKLCH lightness (hue and chroma kept, chroma
reduced only when the step leaves the sRGB gamut) away from the surface until
the pair passes; the Catppuccin value is used only when stepping can't get
there. `--check PALETTE.json` verifies a palette against the same contract
(used by the design-contrast flake check for the static Catppuccin palettes).
"""

import argparse
import json
import math
import os
import re
import sys

# Minimum ratios (WCAG 2.2): TEXT for body text, STRONG for the primary text
# role on its own surface, UI for glyphs, large/bold labels, focus rings and
# other non-text indicators.
TEXT = 4.5
STRONG = 7.0
UI = 3.0

# Opaque surfaces text may sit on (the two higher containers only carry
# large/UI text: hover fills, scrollbars, borders).
SURFACES = ["surface", "surfaceContainerLow", "surfaceContainer"]

# Terminal colours 1-6 (text-grade) from the (harmonised) accent slots.
ANSI = {"red": "ansiRed", "green": "ansiGreen", "yellow": "ansiYellow",
        "blue": "ansiBlue", "pink": "ansiMagenta", "teal": "ansiCyan"}

# (role, surface, minimum). Order matters: text roles first (tiers and mixes
# derive from them), then accents, status colours and the "on" pairs.
CONTRACT = (
    [("fg", "surface", STRONG)]
    + [("fg", s, TEXT) for s in SURFACES]
    + [("fg", s, UI) for s in ["surfaceContainerHigh", "surfaceContainerHighest"]]
    + [("fgMuted", s, TEXT) for s in SURFACES]
    + [("fgFaint", s, UI) for s in ["surface", "surfaceContainerLow"]]
    + [("outline", s, UI) for s in ["surface", "surfaceContainerLow"]]
    # Fills are stepped, never their "on" colour: the pair is written on the
    # fill (contrast is symmetric), so a light-mode selection gets deeper
    # while its text stays the surface colour.
    + [("accent", s, UI) for s in SURFACES + ["onAccent"]]
    + [("accentText", s, TEXT) for s in ["surface", "surfaceContainerLow"]]
    + [("selection", s, UI) for s in ["surface", "surfaceContainerLow"]]
    + [("selection", "onSelection", TEXT)]
    + [(k, s, TEXT) for k in ["error", "warning", "success", "info"]
       for s in ["surface", "surfaceContainerLow", "on" + k.capitalize()]]
    + [("inverseSurface", "onInverseSurface", STRONG)]
    + [(k, s, TEXT) for k in ANSI.values() for s in ["surface", "surfaceContainerLow"]]
)


# Text tiers on `surface` (design targets; fgMuted/fgFaint are then held to
# the contract above).
TIERS = {"fgDim": 9.0, "fgMuted": 6.6, "fgFaint": 4.6}

# Catppuccin accents: harmonised towards the wallpaper's source colour.
ACCENTS = [
    "rosewater", "flamingo", "pink", "mauve", "red", "maroon", "peach",
    "yellow", "green", "teal", "sky", "sapphire", "blue", "lavender",
]

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


def _cbrt(x):
    return math.copysign(abs(x) ** (1 / 3), x)


def to_oklch(h):
    r, g, b = (_lin(c) for c in to_rgb(h))
    l_ = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m_ = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s_ = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return L, math.hypot(A, B), math.degrees(math.atan2(B, A)) % 360


def _oklch_linear(L, C, H):
    A, B = C * math.cos(math.radians(H)), C * math.sin(math.radians(H))
    l_ = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m_ = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s_ = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    return (4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
            -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
            -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_)


def from_oklch(L, C, H):
    """OKLCH -> sRGB hex; chroma is reduced (never clipped) to stay in gamut."""
    L = max(0.0, min(1.0, L))
    for _ in range(32):
        rgb = _oklch_linear(L, C, H)
        if all(-1e-6 <= c <= 1 + 1e-6 for c in rgb):
            break
        C *= 0.85
    return to_hex([_delin(max(0.0, min(1.0, c))) for c in rgb])


def harmonize(colour, source):
    """Rotate colour's hue towards source by min(diff/2, 15deg) (Material)."""
    L, C, H = to_oklch(colour)
    _, _, Hs = to_oklch(source)
    diff = (Hs - H + 180) % 360 - 180
    return from_oklch(L, C, H + math.copysign(min(abs(diff) * 0.5, 15), diff))


def is_dark(p):
    return luminance(p["surface"]) < 0.18


def step(fg, pairs, dark):
    """Step fg's OKLCH lightness until every (background, minimum) passes.

    Darker in light mode, lighter in dark mode (the way Material tones move
    towards tone 40 / tone 80). Hue and chroma are kept (chroma shrinks only
    at the gamut edge), so a lavender stays a lavender; it just gets deeper
    on a light surface or lighter on a dark one. None when no lightness
    reaches the target.
    """
    pairs = [(b, m) for b, m in pairs if b]

    def ok(c):
        return all(contrast(c, b) >= m for b, m in pairs)

    if ok(fg):
        return fg
    L, C, H = to_oklch(fg)
    direction = 1 if dark else -1
    for i in range(1, 101):
        cand = from_oklch(L + direction * i * 0.01, C, H)
        if ok(cand):
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
        "accentText": r["primary"],
        "primary": r["primary"],
        "onAccent": r["on_primary"],
        "selection": r["primary"],
        "onSelection": r["on_primary"],
        "error": r.get("error"),
        "onError": r.get("on_error"),
        "surface": r["surface"],
        "surfaceContainerLow": r.get("surface_container_low"),
        "surfaceContainer": r.get("surface_container"),
        "surfaceContainerHigh": r.get("surface_container_high"),
        "surfaceContainerHighest": r.get("surface_container_highest"),
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
    # Status colours are semantic, so their hues are fixed across palettes:
    # the Catppuccin peach/green/blue (not harmonised, which could pull a
    # warning towards the error hue), stepped to the contract below. error
    # stays matugen's (Material keeps it fixed too).
    for role, slot in (("warning", "peach"), ("success", "green"), ("info", "blue")):
        if HEX.match(str(fallback.get(slot, ""))):
            p[role] = fallback[slot]
    return {k: v for k, v in p.items() if v}


def seed_roles(p):
    """Roles the generator derives from others when the source lacks them."""
    pole = (p.get("crust") or p["surface"]) if is_dark(p) else p["surface"]
    p.setdefault("surfaceContainerHighest", p.get("surface2", p["surfaceContainerHigh"]))
    p.setdefault("fg", p["text"])
    p.setdefault("fgMuted", p["subtext0"])
    p.setdefault("fgFaint", p["overlay2"])
    p.setdefault("accentText", p["accent"])
    p.setdefault("selection", p["accent"])
    p.setdefault("onSelection", pole)
    p.setdefault("warning", p["peach"])
    p.setdefault("success", p["green"])
    p.setdefault("info", p["blue"])
    for k in ["error", "warning", "success", "info"]:
        p.setdefault("on" + k.capitalize(), pole)
    for slot, role in ANSI.items():
        p.setdefault(role, p[slot])


def enforce(p, fallback, log=print):
    """Apply CONTRACT: step every failing role, Catppuccin value as last resort."""
    dark = is_dark(p)
    by_role = {}
    for role, surface, minimum in CONTRACT:
        by_role.setdefault(role, []).append((surface, minimum))
    for role, pairs in by_role.items():
        if role not in p or any(s not in p for s, _ in pairs):
            continue
        bgs = [(p[s], m) for s, m in pairs]
        fixed = step(p[role], bgs, dark)
        if fixed is None:
            fb = fallback.get(role)
            where = ", ".join("%s %.1f:1" % (s, m) for s, m in pairs)
            if isinstance(fb, str) and step(fb, bgs, dark) == fb:
                fixed = fb
                log("theme-palette: %s can't reach %s; Catppuccin value" % (role, where))
            else:
                fixed = p[role]
                log("theme-palette: %s stays below %s" % (role, where))
        p[role] = fixed


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
        # Roles seed_roles() derives must come from the wallpaper, not from
        # the Catppuccin fallback.
        for k in ["fg", "fgMuted", "fgFaint", "accentText", "selection",
                  "onSelection", "warning", "success", "info", "onError",
                  "onWarning", "onSuccess", "onInfo", "focus"] + list(ANSI.values()):
            p.pop(k, None)
        p.update(wall)
        seed_roles(p)
        enforce(p, fallback, lambda m: print(m, file=sys.stderr))  # text first
        derive(p)  # tiers and mixes from the guarded text
        seed_roles(p)
        enforce(p, fallback, lambda m: print(m, file=sys.stderr))
        p["focus"] = p["accent"]  # the focus ring is the (guarded) accent
    p.update({k: v.lower() for k, v in pinned.items()
              if isinstance(v, str) and HEX.match(v)})
    return p


def check(p, name=""):
    """Return the CONTRACT violations of palette p as (role, surface, ratio, min)."""
    bad = []
    for role, surface, minimum in CONTRACT:
        if role in p and surface in p:
            c = contrast(p[role], p[surface])
            if c < minimum - 1e-9:
                bad.append((role, surface, c, minimum))
    return bad


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
    ap.add_argument("--check", metavar="PALETTE.json", action="append",
                    help="verify palettes against the contract and exit")
    ap.add_argument("--matugen", help="matugen --json hex dump")
    ap.add_argument("--mode", choices=["light", "dark"])
    ap.add_argument("--fallback", help="Catppuccin palette JSON")
    ap.add_argument("--pinned", help='JSON {"light": {...}, "dark": {...}}')
    ap.add_argument("--templates")
    ap.add_argument("--out")
    a = ap.parse_args()

    if a.check:
        failed = 0
        for path in a.check:
            with open(path) as f:
                data = json.load(f)
            palettes = data if "light" in data and "dark" in data else {"": data}
            for mode, p in palettes.items():
                label = "%s%s" % (path, " [%s]" % mode if mode else "")
                for role, surface, c, minimum in check(p):
                    failed += 1
                    print("FAIL %s: %s on %s = %.2f:1 (min %.1f)"
                          % (label, role, surface, c, minimum))
        print("theme-palette --check: %d violation(s)" % failed)
        sys.exit(1 if failed else 0)

    for k in ("matugen", "mode", "fallback", "templates", "out"):
        if getattr(a, k) is None:
            ap.error("--%s is required" % k)
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
    for role, surface, c, minimum in check(palette):
        print("theme-palette: %s on %s = %.2f:1 < %.1f (pinned?)"
              % (role, surface, c, minimum), file=sys.stderr)
    render(a.templates, a.out, palette, fallback)


if __name__ == "__main__":
    main()
