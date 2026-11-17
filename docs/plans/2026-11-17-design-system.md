# Design system — audit, tokens, signature (2026-11-17)

Status: **implemented in the working tree, not yet switched**. Extends
`2026-11-17-aesthetics-design.md` (architecture, wallpaper subsystem, phases);
this document owns the *look*: colour roles with a contrast contract, the
token scales, the signature, and the audit that motivated them.

Scope: Sway on butternut (external monitor, Catppuccin source) and hazel
(14" panel, `theme.source = "wallpaper"`); maple/peacelily are headless and
untouched. Taste constraints: tiling, calm, legible; **no blur, no
transparency**; vertical collapsible bar on the right; darkman light/dark.

Where things live:

| what | where |
|---|---|
| colour roles + Catppuccin mappings | `modules/theme.nix` (`mkPalette`, `palettes.catppuccin`) |
| non-colour tokens (`self.design`) | `modules/design-tokens.nix` |
| contract + wallpaper guard (OKLCH stepping) | `modules/nixos/extra/theme-palette.py` (`CONTRACT`, `step`, `enforce`) |
| flake check | `checks.design-contrast` in `modules/checks.nix` |
| rendered palette files per mode | `nixosConfigurations.<host>.config.preferences.theme.rendered.{light,dark}` |

## 1. Audit (before)

Method: every (foreground, background) pair the themed modules emit, WCAG 2.2
relative-luminance contrast, for six palettes: Catppuccin Latte and Mocha,
and the matugen palettes generated from both bundled default wallpapers
("dunes" = `minimal-hike-on-the-dunes.jpg`, "lake" = `stars-in-a-lake.jpg`)
in light and dark. Thresholds: 4.5:1 text, 3:1 glyphs / large or bold UI text
/ non-text indicators and focus rings; decorative hairlines have none.
Scripts: scratchpad `audit.py` (before) and the generator's `--check` (after).

### 1.1 Headline

| palette | pairs | failures before | after |
|---|---|---|---|
| Catppuccin Latte | 81 | **40** | 0 |
| Catppuccin Mocha | 81 | 6 | 0 |
| dunes, light | 81 | 8 | 0 |
| dunes, dark | 81 | 7 | 0 |
| lake, light | 81 | 8 | 0 |
| lake, dark | 81 | 7 | 0 |
| **total** | | **76** | **0** (88 pairs after; terminal ANSI slots now included) |

### 1.2 Surfaces, roles and failures

Sizes/spacing/radii are the values before this change; the "after" column
names the token that replaced them.

| surface | fg on bg (role) | Latte | Mocha | dunes L | sizes / spacing before → after |
|---|---|---|---|---|---|
| **waybar** item glyph | `fg` on `surfaceContainerLow` | 6.6 | 12.1 | 15.5 | 16 px glyph, padding 6/0, margin 2/4, radius 6, bar padding 8 → `bar.*` (padding 4, margin 2/4, radius 6, edge 8); glyph font `type.family.glyph` |
| waybar accent glyph (agents, caffeine, sync…) | `accent` | **2.6** | 9.8 | 5.9 | — |
| waybar warning glyph + value text | `peach` | **2.5** | 9.9 | **3.5**¹ | `warning` |
| waybar success glyph | `green` | **2.8** | 11.8 | **3.7**¹ | `success` |
| waybar error value text (small) | `error` | **4.46** | 7.6 | 5.9 | `error` (stepped to 4.5) |
| waybar calendar month / today | `accent` / `peach` on `surface` | **2.8** / **2.6** | 9.2 / 9.3 | 6.1 / — | `accentText`; today = `onSelection` on `selection` plate |
| waybar calendar week numbers | `fgFaint` on `surface` | **3.5** | 5.8 | 4.6 | `fgMuted` (it is text) |
| waybar tooltip | `fg` on `surface`, 1 px `outlineVariant`, radius 8, Inter 12 | 7.1 | 11.3 | 16.3 | `panel.*`, `type.size.body` |
| waybar value text | Pango `size='small'` (≈13 px of 16) | | | | `type.size.caption` (11 px) |
| waybar bar edge | 1 px `hairline` | deco | | | `bar.rule` |
| **swaync** toast | `fg` on `surface`, 1 px `outlineVariant`, radius 8, margin 6, padding 10 | 7.1 | 11.3 | 16.3 | `panel.radius` 8, `panel.margin` 8, `panel.padding` 12 |
| swaync body | `fgMuted` on `surface` | **4.37** | 7.4 | 6.6 | `fgMuted` stepped (Latte 6.2) |
| swaync time | `fgFaint` on `surface` | **3.5** | 5.8 | 4.6 | `fgMuted`, `type.size.caption` |
| swaync action button | `fg` on `surfaceContainerLow`, 1 px `surfaceContainer`, radius 6, margin 4 | 6.6 | 12.1 | 15.5 | `radius.control`, `panel.gap`, hover `tint10`, focus ring |
| swaync close hover | `surface` on `error` | 5.0 | 7.1 | 6.1 | `onError` on `error` |
| swaync DND switch off / on | `outlineVariant` / `inverseSurface` on `surfaceContainerLow` | **1.5** / 7.0 | **1.9** / 12 | **1.6** / 11 | `outline` border (3.2 / 4.8 / 4.0), on = `selection` + `onSelection` knob |
| swaync title | 15 px bold | | | | `type.size.title`, weight `medium` |
| **swayosd** (stock css) | `alpha(@theme_bg_color, 0.8)` — **translucent**, radius 999, 6 px bar | — | — | — | opaque `surface` + hairline + `panel.radius`; `osd.barHeight` 4; bar `accent` on `surfaceContainerHigh` |
| **swaylock** clock / date | `fg` on `surface` disc, 32 px | 7.1 | 11.3 | 16.3 | `type.size.display` |
| swaylock idle ring | `outlineVariant` on `surface`, 8 px thick, radius 120 | **1.6** | **1.8** | **1.6** | `outline` (3.5 / 4.4 / 4.2), `lock.ringThickness` 4 |
| swaylock verifying ring / text | `accent` | **2.8** | 9.2 | 6.1 | `accent` ring, `accentText` text |
| swaylock caps-lock text | `peach` | **2.6** | 9.3 | **3.5**¹ | `warning` |
| swaylock layout box border | `outlineVariant` | **1.6** | | | `outline` |
| **sway** focused border | `accent` vs window `surface`, 2 px | **2.8** | 9.2 | 6.1 | `focus` (4.2 / 9.2 / 6.1), `window.border` 2 |
| sway unfocused border | `surface0` | deco | | | `outlineVariant` |
| sway gaps | inner 6, outer 0 | | | | `window.gap` 8 (= `bar.edgePadding`) |
| sway urgent | `error` border | 5.0 | 7.1 | 6.1 | `error` border, `onError` title |
| **GTK** (adw-gtk3 / libadwaita) window text | `fg` on `surface` | 7.1 | 11.3 | 16.3 | — |
| GTK selected row / text (**Thunar bug**) | `onAccent` on `accent` | **2.8** | 10.5 | 6.5 | `onSelection` on `selection` (4.6 / 10.5 / 6.5) |
| GTK destructive / warning / success buttons | `surface` on `red`/`peach`/`green` | 5.0 / **2.6** / **3.0** | 7.1 / 9.3 / 11 | 6.1 / **3.5** / **3.7** | `onError`/`onWarning`/`onSuccess` on the status roles |
| GTK links, `accent_color` | `accent` on `surface` | **2.8** | 9.2 | 6.1 | `accentText` |
| GTK focus ring | adw-gtk3 default: translucent accent outline | | | | 2 px solid `focus`, inset |
| **Qt** (qt6ct + Fusion) highlight | `onInverseSurface` on `inverseSurface` | 7.1 | 11.3 | 11.6 | `onSelection` on `selection` (toolkit selection) |
| Qt placeholder text | `fgFaint` on `surface` | **3.5** | 5.8 | 4.6 | `fgMuted` |
| Qt disabled text | `fgFaint` on `surfaceContainerLow` | 3.2 (exempt) | 6.2 | 4.4 | unchanged, documented exempt |
| Qt link | `accent` | **2.8** | 9.2 | 6.1 | `accentText` |
| **kitty** fg / selection / url | `fg`; `onInverseSurface` on `inverseSurface`; `accent` | 7.1 / 7.1 / **2.8** | 11.3 / 11.3 / 9.2 | 16 / 11.6 / 6.1 | url `accentText`; caret `selection`+`onSelection` |
| kitty ANSI 2/3/5/6 as text (green, yellow, magenta, cyan) | Catppuccin slots on `surface` | **3.0 / 2.3 / 2.3 / 3.3** | 11 / 13 / 11 / 11 | **3.2 / 2.5 / 2.5 / 3.6** | `ansiGreen/Yellow/Magenta/Cyan` (4.9 / 4.9 / 5.0 / 5.0 in Latte) |
| kitty ANSI 4 blue, 15 bright white | `blue`, `subtext0` | **4.34**, **4.37** | 7.8, 9.0 | 4.47, 6.6 | `ansiBlue`, `fg` |
| kitty inactive tab | `fgMuted` on `surfaceContainerLow` | **4.1** | 7.9 | 6.3 | `fgMuted` stepped (5.7) |
| **vicinae** (built-in Catppuccin themes) | own hex, border `surface2`, radius 8, 1 px | ≈ Latte | ≈ Mocha | n/a (not wallpaper-reactive) | generated `vicinae.toml` from the palette; `panel.*` |
| **zathura** statusbar | `fgMuted` on `surfaceContainerLow` | **4.1** | 7.9 | 6.3 | stepped `fgMuted` |
| zathura warning | `peach` | **2.6** | | | `warning` |
| **wofi** (dmenu prompts) | `text` on `base`, radius 8/6, paddings 5/10/20, 0.2–0.5 s fades | 7.1 | | | `panel.*`, `space.*`, no fades |
| **btop** inactive text | `overlay1` on `base` | **2.8** | **4.4** | **2.5** | `fgMuted` |
| btop selected row | `blue` on `surface1` | **2.7** | **4.3** | **4.1** | `onInverseSurface` on `inverseSurface` |
| btop dividers | `overlay0` | **2.3** | 2.9 | **1.6** | `outlineVariant` (decorative) |
| **noctalia** `on_primary` | `onAccent` on `accent` | **2.8** | 10.5 | 6.5 | `onSelection` on `selection` |
| **wlr-which-key** (niri only) | Gruvbox base16 (`self.theme`), radius 15, 2 px border, padding 15 | — | — | — | palette dark roles, `panel.*` |
| **greetd/tuigreet** (VT) | kernel console default colours | — | — | — | `console.colors` from the dark palette |
| **fonts** | Inter (UI), JetBrainsMono Nerd Font (bar/terminal), Noto Sans Arabic fallback; `tnum` for Inter; sway title 9.6 pt | | | | IBM Plex Sans / Mono (BlexMono NF) / Sans Arabic, see §2.3 |

¹ wallpaper palettes harmonised the Catppuccin peach/green towards the
wallpaper's hue, then only nudged text to 4.5 on `surface`; glyphs on the bar
background were not covered.

Other inconsistencies found: radii 6 / 8 / 12 (swaync switch) / 15
(which-key) / 100 % (close button); spacings 5, 6, 10, 15, 20, 25 off the 4 px
scale; three font sizes for the same bar (16, 14, 12 px, plus "small");
swaync `transition-time` 120 ms vs the tray drawer's 170 ms; wofi fades of
200–500 ms; delta forced the light `GitHub` syntax theme in dark terminals.

## 2. The system

### 2.1 Signature: **"one ink on paper"**

Candidates considered:

| direction | pitch | bar / notifications / launcher / lock / OSD / borders / GTK selection / terminal | risks |
|---|---|---|---|
| **A. One ink on paper** (chosen) | Surfaces are flat tonal paper separated only by hairlines and tonal steps; exactly one chromatic element in the chrome, the *ink*, and it marks **where input goes**. | Bar: achromatic glyphs, ink only for "live" states; toasts: paper card + hairline, ink only on the focused control; launcher: paper, the chosen row by inversion, ink on the input border; lock: paper disc + thin ink ring that lights per keystroke; OSD: paper + thin ink level line; borders: 2 px ink on the focused window, hairline elsewhere; GTK/Qt: ink selection fill with guaranteed text; terminal: ink caret, inverted selection. | Low-chroma palettes look austere; the ink must pass 3:1 as a rule and 4.5:1 as a fill in *light* mode, which deepens Catppuccin's pastel lavender (handled by the contract). |
| B. Strict 8-grid | Gaps equal the bar's padding; every edge in the desktop aligns to one grid. | Mostly spacing; little to say about colour. | Easy to break by one app; invisible unless the grid is tight. |
| C. Monospace-forward technical | Plex Mono everywhere, tabular data look. | Bar and launcher in mono; notifications in mono. | Arabic has no mono; long notification bodies read badly in mono. |

A absorbs B's useful part (one spacing scale, gap = bar edge padding) and
gives colour a rule a future agent can apply without taste: *is this where the
user's input goes? then ink; otherwise paper, hairline or inversion.*

**Signature rules** (the 5 a future agent follows):

1. **Paper, not glass.** Every surface is opaque. Depth is a tonal step
   (`surface` → `surfaceContainerLow` → `surfaceContainer`) or a 1 px
   hairline in `outlineVariant`; never a shadow, alpha, or blur.
2. **One ink, where input goes.** The accent appears only on the focused
   window border, the focus ring, the caret, the text selection, the active
   toggle, and bar states that mean "live" (agent working, syncing, caffeine
   on). It is a **2 px rule** by default (`border.focus`) and a fill only as
   `selection`, whose text (`onSelection`) is guaranteed ≥ 4.5:1.
3. **Emphasis by inversion.** The chosen item in our own pickers (launcher,
   wofi, terminal selection, btop, zathura index) is an ink plate in
   `inverseSurface`/`onInverseSurface` (≥ 7:1), not a tinted row.
4. **Status is text-grade and hue-fixed.** `error`, `warning`, `success`,
   `info` pass 4.5:1 on both bar and panel surfaces in every palette, and
   keep the Catppuccin hue even under a wallpaper palette, so orange always
   means warning.
5. **One family, one rhythm.** IBM Plex everywhere (Sans, Mono, Sans
   Arabic), the 4 px scale, two radii (6 control, 8 panel), motion ≤ 210 ms
   and only for reveals.

### 2.2 Colour roles and the contrast contract

Roles (keys of `config.preferences.theme.palette.{light,dark}`, same for
Catppuccin and wallpaper palettes). Minimums are WCAG 2.2 ratios, guaranteed:

| role | use | guaranteed |
|---|---|---|
| `surface`, `surfaceContainerLow`, `surfaceContainer`, `surfaceContainerHigh`, `surfaceContainerHighest` | window paper, bar/sidebar paper, cards/buttons, hover/trough, pressed | — |
| `fg` | primary text | ≥ 7:1 on `surface`; ≥ 4.5 on Low/Container; ≥ 3 on High/Highest (UI only) |
| `fgMuted` | secondary text, timestamps, placeholders | ≥ 4.5 on `surface`, Low, Container |
| `fgFaint` | indicators, disabled, "off" glyphs — **never body text** | ≥ 3 on `surface`, Low |
| `outline` | visible borders: switches, lock ring, input frames | ≥ 3 on `surface`, Low |
| `outlineVariant` | hairlines, panel borders, unfocused window borders | none (decorative) |
| `accent` | the ink as a rule or glyph | ≥ 3 on the three text surfaces; ≥ 3 vs `onAccent` |
| `accentText` | the ink as text (links, calendar month, URLs) | ≥ 4.5 on `surface`, Low |
| `selection` / `onSelection` | the ink as a fill (GTK/Qt selection, toggles on, today, caret) | ≥ 3 on `surface`, Low; `onSelection` ≥ 4.5 on it |
| `focus` | focus rings and the focused window border (= `accent`) | as `accent` |
| `error`, `warning`, `success`, `info` + `onError`… | status glyphs *and* text, status fills | ≥ 4.5 on `surface`, Low; on-colour ≥ 4.5 |
| `inverseSurface` / `onInverseSurface` | emphasis by inversion | ≥ 7 |
| `ansiRed/Green/Yellow/Blue/Magenta/Cyan` | terminal colours 1–6 (bright = same) | ≥ 4.5 on `surface`, Low |
| `hairlineSoft/hairline/hairlineStrong`, `tint5/10/16` | opaque fg-over-surface mixes: separators; hover (10) and pressed (16) | derived |
| 26 Catppuccin slots | terminal spec colours, decorative accents, lookups (`accentName`) | — |

How the guarantee is kept:

- **Catppuccin** (`modules/theme.nix`): slots map to roles; where a Latte slot
  misses, `roles` overrides it with the value produced by the generator's
  OKLCH step (hue and chroma kept, lightness moved until the pair passes):
  `accent` lavender L 0.66 → 0.56 (`#5768da`), `accentText` `#4c5bcd`,
  `selection` `#5161d4`, `fgMuted` `#56586d`, `outline` = overlay2, `error`
  `#ce0436`, `warning` `#af4816`, `success` `#297816`, `info` `#135cea`,
  `ansiYellow` `#925c13`, `ansiMagenta` `#a93a8f`, `ansiCyan` `#097277`.
  Mocha passes untouched except `outline` = overlay1.
- **Wallpaper** (`theme-palette.py`): Material roles → palette shape, then
  `enforce()` walks `CONTRACT` and steps each failing role in OKLCH
  (darker in light mode, lighter in dark mode; chroma reduced only at the
  gamut edge), falling back to the Catppuccin value only when no lightness
  reaches the target. Fills are stepped, never their "on" colour (the pair is
  written on the fill), so a light-mode selection gets deeper while its text
  stays the surface colour. Status hues are not harmonised. `--check`
  verifies any palette JSON against the same contract.
- **Check**: `nix build .#checks.x86_64-linux.design-contrast` — static
  Catppuccin palettes, matugen palettes from both bundled wallpapers in both
  modes, and a grep for hardcoded hex in `modules/nixos` and
  `modules/wrappedPrograms` (`modules/theme.nix` is the one place).

#### Final pairs (after)

Bold would mark a failure; there are none. "dunes"/"lake" are the two bundled
default wallpapers, L/D the mode.

| pair | min | Latte | Mocha | dunes L | dunes D | lake L | lake D |
|---|---|---|---|---|---|---|---|
| `fg` on `surface` | 7.0 | 7.1 | 11.3 | 16.3 | 14.4 | 16.3 | 14.3 |
| `fg` on `surfaceContainerLow` | 4.5 | 6.6 | 12.1 | 15.5 | 13.3 | 15.4 | 13.2 |
| `fg` on `surfaceContainer` | 4.5 | 5.2 | 8.7 | 14.7 | 12.7 | 14.7 | 12.6 |
| `fg` on `surfaceContainerHigh` | 3.0 | 4.4 | 6.3 | 14.0 | 11.2 | 14.0 | 11.1 |
| `fg` on `surfaceContainerHighest` | 3.0 | 3.7 | 4.6 | 13.3 | 9.6 | 13.2 | 9.5 |
| `fgMuted` on `surface` | 4.5 | 6.2 | 7.4 | 6.6 | 6.6 | 6.7 | 6.6 |
| `fgMuted` on `surfaceContainerLow` | 4.5 | 5.7 | 7.9 | 6.3 | 6.1 | 6.3 | 6.1 |
| `fgMuted` on `surfaceContainer` | 4.5 | 4.5 | 5.6 | 6.0 | 5.9 | 6.0 | 5.9 |
| `fgFaint` on `surface` | 3.0 | 3.5 | 5.8 | 4.6 | 4.6 | 4.6 | 4.6 |
| `fgFaint` on `surfaceContainerLow` | 3.0 | 3.2 | 6.2 | 4.4 | 4.3 | 4.4 | 4.3 |
| `outline` on `surface` | 3.0 | 3.5 | 4.4 | 4.2 | 5.8 | 4.3 | 5.8 |
| `outline` on `surfaceContainerLow` | 3.0 | 3.2 | 4.8 | 4.0 | 5.4 | 4.1 | 5.4 |
| `accent` on `surface` | 3.0 | 4.2 | 9.2 | 6.1 | 10.9 | 6.1 | 10.8 |
| `accent` on `surfaceContainerLow` | 3.0 | 3.9 | 9.8 | 5.9 | 10.1 | 5.8 | 10.0 |
| `accent` on `surfaceContainer` | 3.0 | 3.1 | 7.0 | 5.6 | 9.6 | 5.5 | 9.6 |
| `accent` on `onAccent` | 3.0 | 4.2 | 10.5 | 6.5 | 7.8 | 6.4 | 7.7 |
| `accentText` on `surface` | 4.5 | 5.0 | 9.2 | 6.1 | 10.9 | 6.1 | 10.8 |
| `accentText` on `surfaceContainerLow` | 4.5 | 4.7 | 9.8 | 5.9 | 10.1 | 5.8 | 10.0 |
| `selection` on `surface` | 3.0 | 4.6 | 9.2 | 6.1 | 10.9 | 6.1 | 10.8 |
| `selection` on `surfaceContainerLow` | 3.0 | 4.3 | 9.8 | 5.9 | 10.1 | 5.8 | 10.0 |
| `selection` on `onSelection` | 4.5 | 4.6 | 10.5 | 6.5 | 7.8 | 6.4 | 7.7 |
| `error` on `surface` | 4.5 | 5.0 | 7.1 | 6.1 | 10.9 | 6.1 | 10.9 |
| `error` on `surfaceContainerLow` | 4.5 | 4.7 | 7.6 | 5.9 | 10.1 | 5.8 | 10.1 |
| `error` on `onError` | 4.5 | 5.0 | 8.1 | 6.5 | 7.7 | 6.5 | 7.7 |
| `warning` on `surface` | 4.5 | 4.9 | 9.3 | 4.9 | 10.5 | 4.9 | 10.4 |
| `warning` on `surfaceContainerLow` | 4.5 | 4.6 | 9.9 | 4.6 | 9.7 | 4.6 | 9.7 |
| `warning` on `onWarning` | 4.5 | 4.9 | 10.6 | 4.9 | 10.9 | 4.9 | 10.9 |
| `success` on `surface` | 4.5 | 4.9 | 11.0 | 4.8 | 12.4 | 4.8 | 12.4 |
| `success` on `surfaceContainerLow` | 4.5 | 4.6 | 11.8 | 4.6 | 11.5 | 4.6 | 11.5 |
| `success` on `onSuccess` | 4.5 | 4.9 | 12.6 | 4.8 | 12.9 | 4.8 | 13.0 |
| `info` on `surface` | 4.5 | 5.0 | 7.8 | 4.9 | 8.8 | 4.9 | 8.8 |
| `info` on `surfaceContainerLow` | 4.5 | 4.6 | 8.3 | 4.6 | 8.1 | 4.6 | 8.1 |
| `info` on `onInfo` | 4.5 | 5.0 | 8.9 | 4.9 | 9.1 | 4.9 | 9.2 |
| `inverseSurface` on `onInverseSurface` | 7.0 | 7.1 | 11.3 | 11.6 | 10.2 | 11.5 | 10.1 |
| `ansiRed` on `surface` | 4.5 | 5.0 | 7.1 | 5.2 | 8.0 | 5.2 | 7.9 |
| `ansiRed` on `surfaceContainerLow` | 4.5 | 4.7 | 7.6 | 5.0 | 7.4 | 4.9 | 7.3 |
| `ansiGreen` on `surface` | 4.5 | 4.9 | 11.0 | 4.8 | 12.5 | 4.8 | 12.5 |
| `ansiGreen` on `surfaceContainerLow` | 4.5 | 4.6 | 11.8 | 4.6 | 11.6 | 4.6 | 11.5 |
| `ansiYellow` on `surface` | 4.5 | 4.9 | 12.9 | 4.8 | 14.7 | 4.7 | 14.7 |
| `ansiYellow` on `surfaceContainerLow` | 4.5 | 4.6 | 13.8 | 4.6 | 13.6 | 4.5 | 13.6 |
| `ansiBlue` on `surface` | 4.5 | 5.0 | 7.8 | 4.8 | 8.9 | 4.7 | 8.8 |
| `ansiBlue` on `surfaceContainerLow` | 4.5 | 4.6 | 8.3 | 4.6 | 8.2 | 4.5 | 8.2 |
| `ansiMagenta` on `surface` | 4.5 | 5.0 | 10.7 | 4.8 | 12.2 | 4.8 | 12.2 |
| `ansiMagenta` on `surfaceContainerLow` | 4.5 | 4.7 | 11.5 | 4.5 | 11.3 | 4.5 | 11.3 |
| `ansiCyan` on `surface` | 4.5 | 5.0 | 11.0 | 4.8 | 12.4 | 4.8 | 12.4 |
| `ansiCyan` on `surfaceContainerLow` | 4.5 | 4.7 | 11.8 | 4.6 | 11.5 | 4.6 | 11.5 |

Role values behind the table:

| role | Latte | Mocha | dunes L | dunes D | lake L | lake D |
|---|---|---|---|---|---|---|
| `surface` | `#eff1f5` | `#1e1e2e` | `#f7f9ff` | `#101417` | `#f8f9ff` | `#111418` |
| `surfaceContainerLow` | `#e6e9ef` | `#181825` | `#f1f4f9` | `#181c20` | `#f2f3fa` | `#191c20` |
| `surfaceContainer` | `#ccd0da` | `#313244` | `#ebeef3` | `#1c2024` | `#eceef4` | `#1d2024` |
| `surfaceContainerHigh` | `#bcc0cc` | `#45475a` | `#e6e8ed` | `#272a2e` | `#e7e8ee` | `#272a2f` |
| `fg` | `#4c4f69` | `#cdd6f4` | `#181c20` | `#e0e3e8` | `#191c20` | `#e1e2e8` |
| `fgMuted` | `#56586d` | `#a6adc8` | `#565a5e` | `#979b9f` | `#57595e` | `#999ba0` |
| `fgFaint` | `#7c7f93` | `#9399b2` | `#6e7276` | `#7c7f83` | `#6f7276` | `#7d7f84` |
| `outline` | `#7c7f93` | `#7f849c` | `#72787e` | `#8c9198` | `#73777f` | `#8d9199` |
| `outlineVariant` | `#bcc0cc` | `#45475a` | `#c1c7ce` | `#42474d` | `#c3c6cf` | `#43474e` |
| `accent` | `#5768da` | `#b4befe` | `#2a638a` | `#97ccf9` | `#37618e` | `#a1c9fd` |
| `accentText` | `#4c5bcd` | `#b4befe` | `#2a638a` | `#97ccf9` | `#37618e` | `#a1c9fd` |
| `onAccent` | `#eff1f5` | `#11111b` | `#ffffff` | `#003350` | `#ffffff` | `#003259` |
| `selection` | `#5161d4` | `#b4befe` | `#2a638a` | `#97ccf9` | `#37618e` | `#a1c9fd` |
| `onSelection` | `#eff1f5` | `#11111b` | `#ffffff` | `#003350` | `#ffffff` | `#003259` |
| `focus` | `#5768da` | `#b4befe` | `#2a638a` | `#97ccf9` | `#37618e` | `#a1c9fd` |
| `error` | `#ce0436` | `#f38ba8` | `#ba1a1a` | `#ffb4ab` | `#ba1a1a` | `#ffb4ab` |
| `onError` | `#eff1f5` | `#11111b` | `#ffffff` | `#690005` | `#ffffff` | `#690005` |
| `warning` | `#af4816` | `#fab387` | `#b64e1e` | `#fab387` | `#b64e1e` | `#fab387` |
| `onWarning` | `#eff1f5` | `#11111b` | `#f7f9ff` | `#0b0f12` | `#f8f9ff` | `#0b0e13` |
| `success` | `#297816` | `#a6e3a1` | `#307e1e` | `#a6e3a1` | `#307e1e` | `#a6e3a1` |
| `onSuccess` | `#eff1f5` | `#11111b` | `#f7f9ff` | `#0b0f12` | `#f8f9ff` | `#0b0e13` |
| `info` | `#135cea` | `#89b4fa` | `#1b63f1` | `#89b4fa` | `#1b63f1` | `#89b4fa` |
| `onInfo` | `#eff1f5` | `#11111b` | `#f7f9ff` | `#0b0f12` | `#f8f9ff` | `#0b0e13` |
| `inverseSurface` | `#4c4f69` | `#cdd6f4` | `#2d3135` | `#e0e3e8` | `#2e3135` | `#e1e2e8` |
| `onInverseSurface` | `#eff1f5` | `#1e1e2e` | `#eef1f6` | `#2d3135` | `#eff0f7` | `#2e3135` |
| `ansiRed` | `#ce0436` | `#f38ba8` | `#cd0f61` | `#eb8cbe` | `#cd0f61` | `#eb8cbe` |
| `ansiGreen` | `#297816` | `#a6e3a1` | `#027f48` | `#90e6b5` | `#027f48` | `#90e6b5` |
| `ansiYellow` | `#925c13` | `#f9e2af` | `#8e680e` | `#eee7b0` | `#ab5a1d` | `#eee7b0` |
| `ansiBlue` | `#135cea` | `#89b4fa` | `#2570bb` | `#7cb8f8` | `#0c6cde` | `#84b6f9` |
| `ansiMagenta` | `#a93a8f` | `#f5c2e7` | `#a54aaf` | `#ecc5f3` | `#a54aaf` | `#ecc5f3` |
| `ansiCyan` | `#097277` | `#94e2d5` | `#23788b` | `#90e1e3` | `#23788b` | `#90e1e3` |

### 2.3 Typography

Choice: **IBM Plex** — `IBM Plex Sans` (UI), `IBM Plex Mono` as the *BlexMono
Nerd Font* build (terminal, bar glyphs via the `Propo` face), `IBM Plex Sans
Arabic` (Arabic fallback in every generic family), `IBM Plex Serif`
(documents). nixpkgs 26.05: `ibm-plex` 1.1.0 (ships Sans Arabic),
`nerd-fonts.blex-mono` 3.4.0 (has `BlexMono Nerd Font Propo`).

Why, against the alternatives checked (`geist-font` 1.5.0: no Arabic;
`atkinson-hyperlegible-next`: Latin only; Recursive/Commit Mono/Iosevka: no
matching sans or no Arabic): Plex is the only family in nixpkgs where the
Latin sans, the mono and the Arabic were drawn together — same x-height
rhythm, same stroke contrast, matching weights — so the bar's Arabic layout
glyph (`ع`), a Thunar listing of Arabic file names and the terminal read as
one voice. Legibility: Plex Sans has open apertures, a distinguishable
`Il1`, and `tnum` tabular figures (kept on through fontconfig for the clock
and tables); Plex Mono's slashed zero and wide `r/n` spacing suit code; Plex
Sans Arabic keeps generous counters at 12 px, where Noto Sans Arabic's marks
collide. Identity: the squared terminals and the mono's distinctive italics
make the desktop recognisable without being loud.

Type scale (`self.design.type`): caption 11 · body 12 · title 15 · glyph 16 ·
display 32 px; weights 400 / 500 / 700 (bold only for the clock's hour and
Pango `<b>`); line height 1.2 tight, 1.4 body (Arabic needs ≥ 1.4 and body ≥ 12).

| surface | face | size | weight |
|---|---|---|---|
| bar glyphs | BlexMono NF Propo | 16 | 400 |
| bar values, swaync time | Plex Sans | 11 | 400 |
| bar clock (`HH` bold / `MM`), layout label | Plex Sans | 14 / 12 | 700 / 400 |
| tooltips, notifications, launcher, OSD, zathura, Qt, GTK | Plex Sans | 12 | 400 (summary/title 500) |
| notification centre title | Plex Sans | 15 | 500 |
| lock clock | Plex Sans | 32 | 400 |
| terminals, editor | BlexMono NF | 12 | 400 |

### 2.4 Spacing, radius, borders, motion, states (`self.design`)

```
space   xs 2 · sm 4 · md 8 · lg 12 · xl 16 · xxl 24 · xxxl 32      (px)
radius  control 6 (buttons, rows, bar items) · panel 8 (popups, toasts,
        launcher, tooltips, OSD) · pill 999 (switch, close) · none 0
border  hairline 1 (panels, separators, unfocused windows) · focus 2 (ink)
motion  fast 90 (hover/pressed tints) · base 170 (drawers, popups, toasts)
        · slow 210 (wallpaper / mode cross-fade); nothing else animates
bar     edgePadding 8 · itemPaddingY 4 (16 px glyph → 24 px box) ·
        itemMarginX 4 · itemMarginY 2 (28 px pitch) · radius control · rule 1
window  gap 8 (= bar.edgePadding) · border 2
panel   padding 12 · margin 8 (from screen edge / bar) · gap 4 · border 1 · radius 8
lock    ringRadius 120 · ringThickness 4
osd     margin 16 · barHeight 4 · width 320
```

States: hover `tint10`, pressed `tint16`, selected/active `selection` +
`onSelection`, focus 2 px `focus` ring (inset where the toolkit allows),
disabled `fgFaint`, urgent `error`. Elevation without shadow: a panel is
`surface` + 1 px `outlineVariant`; a card inside a panel is
`surfaceContainerLow`; a control is `surfaceContainer`, its hover
`surfaceContainerHigh`.

## 3. Applied

- **waybar** (`waybar.nix`, minimal diff): colours by role (warning/success
  are the status roles, calendar month `accentText`, today an `onSelection`
  on `selection` plate, week numbers `fgMuted`); all paddings/margins/radii
  and font sizes from `self.design`; Plex Sans for the clock, layout label
  and tooltips, BlexMono NF Propo glyphs; pressed state `tint16`; 90 ms
  background transition; tray drawer `motion.base`.
- **sway**: gaps 8 (= bar edge padding), 2 px borders; focused border =
  `focus`, others `outlineVariant`, urgent `error`/`onError`; title font
  Plex Sans.
- **swaync**: panel tokens throughout; `.time` is `fgMuted` caption; action
  buttons with hairline border, `tint10` hover, `focus` border on focus;
  close hover `error`/`onError`; DND switch = `outline` border, `selection`
  when on; mpris card with hairline; transition `motion.base`.
- **swayosd**: new opaque stylesheet (was 80 % alpha): panel chrome, Plex
  Sans label, 4 px ink level bar on `surfaceContainerHigh`; restart hook on
  mode switch.
- **dictation overlay** (`dictation.nix`, `dictation/dictate-overlay.py`):
  GTK4 layer-shell panel, top right next to the bar, `osd.width` wide,
  `panel.*` chrome (opaque `surface`, hairline, radius 8, no shadow); timer
  Plex Sans `title` medium with `tnum`; `error` recording dot (as the bar);
  input level = 4 px `accent` line on a `surfaceContainer` trough; the 2 px
  ink rule under the timer for 2 s at each full minute; text `fg` (latest
  segment) / `fgMuted` (older, status, notes, caption). Every pair is
  already in the contract; palette file `dictation-overlay.css`, read at
  each session start.
- **swaylock** (`swayidle.nix`): idle ring `outline`, caps `warning`,
  verifying text `accentText`, layout box border `outline`, 4 px ring, type
  tokens.
- **GTK** (`gtk.nix`): `accent_color` = `accentText`, `accent_bg_color` =
  `selection` with `onSelection`; destructive/warning/success/error pairs
  from the status roles; `borders` hairline; GTK3 legacy selection names and
  `row:selected` → `selection`/`onSelection` (Thunar fix); 2 px solid focus
  ring.
- **Qt** (`qt.nix`): Highlight = `selection`/`onSelection`, Link =
  `accentText`, placeholder `fgMuted`, fonts from tokens.
- **vicinae**: generated `vicinae.toml` per mode (theme file + two symlinks
  `nixconf-{light,dark}`), `theme.light/dark.name` point at them; chosen row
  by inversion, text selection `selection`, input focus `focus`; panel radius
  and border from tokens; reload hook `vicinae theme set`.
- **kitty** (`desktop.nix`): caret = `selection`/`onSelection`, URL
  `accentText`, borders `focus`/`outlineVariant`, bell `warning`, marks on
  status fills, ANSI 1–6 = `ansi*` roles, 7/15 = `fgDim`/`fg`; **Linux
  console colours** (greetd/tuigreet) from the dark palette.
- **foot**, **zellij**, **noctalia** terminal: same ANSI roles, caret and
  inverted selection; noctalia `primary/secondary/tertiary` = `selection`,
  `info`, `warning` with their on-colours.
- **wofi**: panel tokens, Plex Sans, no fades, `accentText` arrow, inverted
  selection, `selection` drop target with `onSelection`.
- **btop**: `fgMuted` inactive, inverted selection, `accentText`
  highlights, `outline`/`outlineVariant` boxes and dividers.
- **zathura**: `warning` role, Plex Sans. **wlr-which-key** (niri):
  palette dark roles + panel tokens instead of Gruvbox base16. **delta**:
  `detect-dark-light=auto` instead of the light-only `GitHub` theme.
- **fonts**: `self.fonts` → Plex; `desktop.nix` installs `ibm-plex` +
  `nerd-fonts.blex-mono`, fontconfig defaults and `tnum` follow.

## 4. Verification

- `nix build .#checks.x86_64-linux.design-contrast` — passes (0 violations
  in 6 palettes, no hardcoded hex).
- `nix eval` of butternut, hazel and maple — all three evaluate; maple has
  no desktop modules and is unaffected beyond the shared palette data.
- `alejandra` + `deadnix --fail modules` clean; `flake8` clean on the
  generator.
- Built: `preferences.theme.package` (`theme-mode`),
  `preferences.wallpaper.package` (`set-wallpaper`),
  `preferences.theme.rendered.{light,dark,light-template,dark-template}` for
  hazel; rendered files contain no `@@THEME` placeholders, and the templates
  reference only known roles.

After the switch (fish; `doas` for root):

```fish
# 1. Both modes, Catppuccin (butternut) or the current wallpaper palette (hazel)
theme-mode light; sleep 2; theme-mode dark
# 2. Wallpaper palettes (hazel): a bright and a dark image
set-wallpaper ~/Pictures/Wallpapers/minimal-hike-on-the-dunes.jpg
set-wallpaper ~/Pictures/Wallpapers/stars-in-a-lake.jpg
set-wallpaper --unpin           # back to the light/dark default pair
# 3. Inspect the palette that was generated for the current wallpaper
cat ~/.local/state/theme/current/palette.json | jq '{accent, selection, onSelection, warning, fgMuted}'
# 4. Verify the generated palette against the contract (wallpaper source)
python3 ~/nixconf/modules/nixos/extra/theme-palette.py --check ~/.local/state/theme/light/palette.json --check ~/.local/state/theme/dark/palette.json
nix build --no-link .#checks.x86_64-linux.design-contrast
# 5. Fonts landed
fc-match sans-serif; fc-match monospace; fc-match "sans-serif:lang=ar"; fc-list | grep -c "BlexMono Nerd Font Propo"
# 6. Services picked up the new styles
systemctl --user restart swayosd.service swaync.service; swayosd-client --output-volume +0
```

What to look at, in each mode: the focused window has a 2 px ink border and
every other window a hairline; the bar's glyphs are grey except agents
working / caffeine on / a connected device (ink) and warnings (orange,
readable even in light mode); open the notification centre — paper card,
hairline, a *filled* switch when DND is on with legible text; `Mod4+Space`
— the launcher's chosen row is inverted, the input gets an ink border when
focused; Thunar — select a few files: the selection is a deep ink with light
text in light mode (the old bug was pale text on lavender); kitty — the caret
is ink, `ls --color` yellow/cyan are readable on Latte; volume key — an
opaque OSD with a thin ink line; `Mod4+Escape` — lock: paper disc, 4 px grey
ring that lights ink per keystroke, orange with caps lock.

## 5. Follow-ups

- **tuigreet** still uses its own ANSI theme names; the VT palette now
  matches, a `--theme` string could map border/prompt to the ink.
- **neovim** (`wrappedPrograms/neovim/lua/colorscheme.lua`) still carries a
  Gruvbox base16 table for lualine; port to a palette-generated
  `colorscheme.lua` via `preferences.theme.files` + a `links` entry.
- **mako.nix** and **clipse.nix** are legacy (no host imports them) and
  still read Latte slots directly; delete or port when the niri stack goes.
- **VSCodium** uses the Catppuccin extension themes, not the wallpaper
  palette; a generated `workbench.colorCustomizations` file could follow.
- **starship / lazygit / bat** use ANSI colours and therefore the new
  `ansi*` roles automatically; bat's syntax theme could be switched per
  mode like delta's.
- Bar item **active workspace** indicator does not exist (no workspace
  module by design); if one returns, it is a 2 px ink rule on the bar's
  inner edge, not a filled pill.
- Wallpaper palettes with a very low-chroma source still produce an
  achromatic ink; consider a minimum chroma floor in `step()`.
- `alejandra` was run over `modules/` once during this work; files owned by
  the dictation agent may have been reformatted.
