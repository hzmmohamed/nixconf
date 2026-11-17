# Aesthetics & wallpaper-reactive theming — design draft (2026-11-17)

Status: **draft, awaiting taste decisions** (see "Open decisions"). Implement
after butternut is switched to the current build and stable.

Constraints: Sway, vertical collapsible bar on the right, **no blur, no
transparency**, calm and legible, automatic light/dark via darkman.

## Audit (current state)

- Two palettes: `modules/theme.nix` `self.theme` is base16 Gruvbox (only
  maple/legacy files use it); Sway hosts use Catppuccin Latte/Mocha.
- Hardcoded Gruvbox hex in `wrappedPrograms/noctalia/noctalia.nix` (v4, dead)
  and `wrappedPrograms/quickshell/*.qml`.
- Wallpaper is a Gruvbox PNG under a Catppuccin UI; set via autostart with
  `swww-daemon & sleep 0.5` (race); no light/dark variant, no attribution.
- Sway borders are Latte-only (never switch), 4px borders + 8px gaps feel heavy.
- swaylock uses screenshot + blur + vignette (violates no-blur).
- kitty palette fetched at runtime (`kitten themes`), not from the repo;
  VSCodium switched by `sed` on settings.json.
- GTK theme `catppuccin-gtk` is archived upstream; GTK3 (Thunar) and libadwaita
  apps look different; **no Qt theming** (QGIS uses default Fusion); no icon
  theme; zathura unthemed; catppuccin/nix imported but unused.
- Fonts: serif mapped to Open Sans; ~18 font families installed.

## Options for wallpaper-reactive colour

| Option | Verdict |
|---|---|
| Stylix `image` (build-time base16) | Reject — no runtime light/dark; would need two system switches a day |
| Pure-Nix Material You (misterio77) | Optional later add-on for curated wallpapers; can't handle runtime downloads |
| **Runtime matugen** | **Chosen** — any wallpaper, both light & dark, cached per image |
| Noctalia built-in wallpaper theming | Reject as primary — Noctalia-only |

## Architecture

- **One palette shape** consumed by every themed module: 26 Catppuccin slot
  names + semantic aliases (`accent`, `onAccent`, Material-style roles
  `surface`, `surfaceContainerLow`, `onSurface`, `onSurfaceVariant`, `outline`,
  `outlineVariant`, `inverseSurface`, `primary`, `error`) + contrast-tiered text
  roles (`fg` 12:1, `fgDim` 9:1, `fgMuted` 6.6:1, `fgFaint` 4.6:1).
- `preferences.theme.source = "catppuccin" | "wallpaper"`;
  `preferences.theme.palette.{light,dark}`; `preferences.theme.files.<name>`;
  `preferences.theme.reloadHooks.<name>`.
- **Resolution chain** (from ryoku): pinned scheme → wallpaper palette →
  Catppuccin fallback; missing values fall through instead of rendering black.
- **WCAG 4.5:1 contrast guard** on generated palettes.
- Same Nix renderers emit matugen templates (placeholder palette with matugen
  expressions) — one source of truth. Apps include **palette-only files**; their
  configs stay in Nix.
- Runtime state: `~/.local/state/theme/{light,dark}/` + `current` symlink;
  Catppuccin mode links to store paths, wallpaper mode is written by matugen
  (cache `~/.cache/theme/<sha>/`).
- **darkman decides light/dark** (passes `-m` to matugen); one hook:
  `set-wallpaper --mode light|dark` replaces the ~10 per-app scripts.

## `set-wallpaper` (single entry point)

`set-wallpaper FILE` (extension, rotation, CLI) · `--mode M` (darkman) ·
`--restore` (login unit). Steps: resolve state → `awww img` with fade → matugen
(wallpaper mode, cache miss) → flip `current` → dconf color-scheme/gtk/icon →
reload hooks (waybar, swaync, kitty SIGUSR1, sway `include` + reload,
Noctalia IPC) → write `~/.local/state/wallpaper/current.json`. awww runs as a
user service bound to graphical-session.target. Optional rotation timer (off).

Wallpapers: curated openly-licensed set in `assets/wallpapers/` + `meta.json`;
downloads in `~/Pictures/Wallpapers/`, favourites in `…/favourites/`; sidecar
`<file>.json` with attribution (title, creator, license, source URL, sha256).

## vicinae wallpaper extension

TypeScript/Raycast API, packaged via HM `programs.vicinae.extensions` +
`config.lib.vicinae.mkExtension` (verified in HM 26.05). Commands: Search
Openverse (CC0/PDM/BY/BY-SA, wide, ≥1920px), Wikimedia POTD, NASA APOD (warn on
copyrighted entries), Favourites, Current Wallpaper Info. Actions: preview,
apply (download + sidecar + `set-wallpaper`), favourite.

## The look

- Fonts: Inter (UI, tabular numerals), JetBrains Mono Nerd Font (terminal, bar,
  literal data only), Noto Serif, Noto Sans Arabic fallback; trim font list.
- Sway: inner gaps 6, outer 0, smart gaps/borders, 2px borders, no title bars;
  focused border = accent, unfocused = surface0; colours update live.
- Bar: mantle background, 1px hairline rule; workspaces 1–6 always as dots
  (7–9 when occupied), active = taller accent pill (or ryoku-style rail pills
  with app icons); clock HH bold over MM; status icons hide when irrelevant;
  unread dot on the bell.
- Emphasis by inversion (inverse-surface plate) rather than accent fills;
  accent reserved for focus border and data. Hairlines (26/13/42% fg mixed
  opaque), interaction tints 5/10/16%, 6–8px radius, spacing 4/8/12/16/24.
- swaync/vicinae/tooltips: shared radius, 1px border, no shadow.
- swaylock: plain base colour + thin accent ring, no screenshot/blur.
- Cursor: Bibata Modern Classic 24. Icons: Papirus (+ papirus-folders tint).
- GTK: adw-gtk3 / adw-gtk3-dark + generated gtk3/gtk4 css → Thunar and
  libadwaita match and follow the palette. Qt: qt6ct + Fusion + generated
  colour scheme (QGIS).
- Terminal: kitty includes a generated palette; zathura themed; browsers follow
  the portal colour scheme. Motion tokens 90/170/210 ms + reduce-motion switch.

## Phases (each independently switchable)

1. Palette abstraction, no visual change (diff-closures shows no config changes)
2. One state dir + unified light/dark switching; live sway colours; kitty from
   Nix; swaylock without blur
3. Wider coverage: adw-gtk3 + css, qt6ct, icons, zathura, fonts, sway look
4. Wallpaper subsystem (`set-wallpaper`, awww service, curated set)
5. Wallpaper source (matugen) — trial on hazel first
6. vicinae wallpaper extension
7. Noctalia mode palette integration
8. Optional: pure-Nix Material You for curated wallpapers

## Open decisions (user)

1. UI font: Inter?
2. Icons: Papirus?
3. Default wallpapers: curated openly-licensed calm set, or user's favourites?
4. Bar workspaces: simple dots, or rail pills with app icons?
5. Emphasis style: inversion (ryoku) or accent fills?
6. Wallpaper: single image, or a light/dark pair? Rotation on or off?
7. Where to trial wallpaper-reactive mode first: hazel or butternut?

## References

Survey clones in `.repos/survey/` (misterio77 Material You, mostlykiguess
palettes, ladas552 vertical Noctalia bar, tetra-fox stylix, iynaix wallpaper
tooling, ryoku design tokens — GPL-3, re-implement only).
