# Pollen identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the phone app's display name to Pollen and give it an adaptive launcher icon (design B, "Carried").

**Architecture:** Android resources only, plus two UI strings. A vector foreground, a colour background and a monochrome layer make up an adaptive icon in `mipmap-anydpi`. Colours sit in `values`/`values-night`.

**Tech Stack:** Android resources (VectorDrawable, adaptive-icon), Kotlin/Compose, Gradle through `nix run .#phone-app`.

**Spec:** `docs/plans/2026-11-23-phone-pollen-identity.md`

## Global Constraints

- `applicationId`/namespace stay `nixconf.phone`; signing untouched.
- `subtype_dictation` stays "Dictation".
- Icon colours: light `surface` `#eff1f5`, `accent` `#5768da`, `fg` `#4c4f69`; dark `surface` `#1e1e2e`, `accent` `#b4befe`, `fg` `#cdd6f4`. Each carries a role comment.
- Geometry (108 dp canvas): nodes r 5 at (32,69), (76,69); dots r 1.9 at (36.11,61.54), (39.08,57.11), (42.49,53.02) and their mirrors x → 108−x; grain r 10 at (54,46).
- minSdk 31: `mipmap-anydpi` only, no PNG mipmaps.

## Review Focus

- Launchers with themed icons on: the monochrome layer must be present, or the icon comes out as a flat blob.
- Dark mode: the background must come from `values-night`, not a light-only colour.
- The keyboard picker and the IME settings list must show the icon (set on `<application>` and in `method.xml`).
- Text that shows the name must not drift from `app_name`, so the UI reads it with `stringResource(R.string.app_name)`.
- Release update path: a package-id change would orphan the install, so check `aapt2 dump badging` still says `package: name='nixconf.phone'`.

---

### Task 1: Icon resources + manifest

**Files:**
- Create: `app/src/main/res/values/colors.xml`, `app/src/main/res/values-night/colors.xml`
- Create: `app/src/main/res/drawable/ic_launcher_foreground.xml`, `app/src/main/res/drawable/ic_launcher_monochrome.xml`
- Create: `app/src/main/res/mipmap-anydpi/ic_launcher.xml`, `app/src/main/res/mipmap-anydpi/ic_launcher_round.xml`
- Modify: `app/src/main/AndroidManifest.xml` (`<application>`), `app/src/main/res/xml/method.xml`

**Interfaces:**
- Produces: `@color/icon_paper|icon_ink|icon_line`, `@mipmap/ic_launcher`, `@mipmap/ic_launcher_round`.

- [ ] Generate both vectors from the geometry above. Circles are paths; foreground fills use `@color/icon_line` and `@color/icon_ink`, the monochrome layer uses one fill.
- [ ] Render the vector XML back to PNG (light/dark, 48 px) and compare it with the approved render.
- [ ] Verify: `nix run .#phone-app -- build`, then `aapt2 dump badging app-debug.apk` shows `application-icon-*` = `res/mipmap-anydpi/ic_launcher.xml` and `package: name='nixconf.phone'`.

### Task 2: Name

**Files:**
- Modify: `app/src/main/res/values/strings.xml` (`app_name` = "Pollen")
- Modify: `app/src/main/java/nixconf/phone/ui/MainActivity.kt:91` (title = `stringResource(R.string.app_name)`)
- Modify: `app/src/main/java/nixconf/phone/ime/Panel.kt:104` ("No profile yet: open ${app name} on the tailnet once")

- [ ] Verify: `rg -n '"[^"]*Nixconf' app/src` shows no user-visible strings; `aapt2 dump badging` shows `application-label:'Pollen'`; `nix run .#phone-app -- test` passes.
- [ ] Commit both tasks with the spec and this plan.
