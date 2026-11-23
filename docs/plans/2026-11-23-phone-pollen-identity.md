# Phone app identity: Pollen (2026-11-23)

Status: implemented (2026-11-23); small change.

## Intent

The Android companion app (`apps/phone/`) is the phone's general companion
to the machines (dictation today; sync, files, notifications later). It gets
a name, **Pollen** (small things carried between plants; the hosts are
plant-named), and a launcher icon in place of Android's default.

Goals: the launcher, app switcher, settings and keyboard picker say "Pollen"
and show the icon; the icon follows the desktop signature "one ink on paper"
(`2026-11-17-design-system.md` §2.1) and works in light, dark and Android 13+
themed icons, down to ~36 px.

Non-goals: `applicationId`/package `nixconf.phone`, the release key, the repo
and flake names, the `phone-app` script and the profile/server side. The
keyboard subtype keeps "Dictation".

Anti-goals: anything that makes Android see a new app (uninstall, lost
drafts); hardcoded colours with no tie to the palette.

## Approaches (icon)

Four directions were rendered (light/dark/themed, round and squircle, 112,
48 and 36 px):

| | idea | trade-off |
|---|---|---|
| A · Grain | tricolpate pollen grain (three furrows) | bold at small sizes; reads as a fan/radiation sign |
| **B · Carried** (chosen) | an ink grain carried along a dotted arc between two machine nodes | says what the name means; thin at 36 px, fixed by tuning |
| C · P-stem | stem + grain = "P" | strong letter mark; plant meaning subtle |
| D · Voice grain | grain with a waveform cut in | clearest small, but says "voice app", narrower than the companion |

The user picked **B**.

## Design

**Icon (adaptive, 108 dp canvas, content inside the 66 dp safe circle):**

- Background layer: flat paper, `@color/icon_paper`.
- Foreground layer (`res/drawable/ic_launcher_foreground.xml`, vector):
  two `fg` nodes (r 5) at (32,69) and (76,69); six `fg` dots (r 1.9), three
  per side, evenly spaced by arc length along the quadratic
  (32,69)–(54,25)–(76,69), clear of the nodes and the grain by 3.5; the
  grain, the one ink element, r 10 at (54,46).
- Monochrome layer: the same shapes in one colour, for themed icons.
- `res/mipmap-anydpi/ic_launcher.xml` (and `ic_launcher_round.xml`, same
  content); `minSdk` is 31, so no PNG fallbacks are needed.
- Manifest: `android:icon` and `android:roundIcon` on `<application>`.
  The IME service inherits the application icon; `method.xml` takes
  `android:icon` too so the keyboard picker shows it.

**Colours:** `res/values/colors.xml` (Latte) and `res/values-night/colors.xml`
(Mocha): `icon_paper` = palette `surface`, `icon_ink` = `accent`,
`icon_line` = `fg`, each with a comment naming the role in
`modules/theme.nix` (`palettes.catppuccin.{light,dark}`). Static hex is
unavoidable in an APK resource; the role comments keep it traceable. Light
ink is the contract-stepped lavender `#5768da` (≥ 3:1 on `surface`).
Launchers that resolve resources at load time follow the night qualifier;
others show the light set.

**Name:** `app_name` = "Pollen". UI copy: the app screen title
(`ui/MainActivity.kt`) and the keyboard's "No profile yet: open Nixconf on
the tailnet once" (`ime/Panel.kt`) become "Pollen". Code identifiers
(`NixconfTheme`, packages) stay.

## Left to the builder

Exact vector path encoding (circles as two arcs), resource file names,
whether `ic_launcher_round` aliases `ic_launcher`. Verification: render the
vector XML back to PNG for a visual check; `nix run .#phone-app -- test` and
`-- build` on butternut.

## User follow-up

The phone has a debug-signed build; the first release install needs
`adb uninstall nixconf.phone` (drafts on the phone are lost) before
`phone-app install`/the in-app update works. Release: `nix run .#phone-app
-- build --release && nix run .#phone-app -- publish`.
