# Phone dictation keyboard (first phone app)

Approved 2026-11-22. Project; full design.

## Why

The phone (Xiaomi 11T Pro, Android, on the tailnet as `phone`, Syncthing
peer for the vault) is the only device in the fleet that this repo does not
configure. Dictation is the first thing that should behave the same
everywhere:

- Today the phone dictates with a minimal Whisper keyboard app: one mic
  button, the model runs on the phone, poor UX. With a low phone battery
  and a laptop or butternut sitting on the tailnet, the phone still burns
  its own battery on the model.
- Models and vocabulary are set in Nix for the laptops
  (`modules/nixos/features/dictation.nix`, `dictation-server.nix`) but the
  phone has its own, hand-configured copy of everything.

The user mostly works through agents, not the command line, so the phone
side is an app, not a Termux setup. **The app is the phone's companion app
for the whole setup**, and the keyboard is its first part. Later parts
(see Later) live in the same app: a glance at the fleet (butternut's
battery in an ongoing notification), and a voice diary. So the package,
the profile and the server endpoint are named for the setup, not for
dictation alone.

Why not T3 Code's own dictation (checked in the installed T3 0.1.9 source,
`VoiceSettingsPanel.tsx`): it transcribes either with a model T3 manages
on an environment (its catalogue, or a model file path) or through
OpenAI / xAI / OpenRouter with an API key. There is no "custom endpoint"
for a server we run, and it only works inside T3. A keyboard works in every
app (notes, browser, T3). T3 does have a shared and per-project dictionary;
seeding it from the fleet vocabulary is a possible follow-up. Termux stays a small tool (pasting
privileged commands an agent hands over), out of scope here.

## Goals

1. An Android keyboard (input method) whose job is dictation: tap the mic,
   speak, the text lands in the focused field. A button switches back to
   the previous keyboard.
2. Remote first: the audio goes to the first reachable whisper server
   (butternut's `dictation-server`, `POST /inference`, Whisper
   large-v3-turbo on the GPU) over the tailnet. Same order and same
   endpoint as the desktop `dictate` client.
3. Local fallback, offline: when no server answers, transcribe on the phone
   with **the same model the laptops use offline**, Parakeet TDT 0.6B v2
   int8 through sherpa-onnx (Android AAR). English only, like on the
   laptops.
4. One source of truth: server list, vocabulary, model URL + hash and
   language settings come from this repo as a **phone profile** (JSON),
   generated from the same Nix options the laptops use. The app fetches it
   over the tailnet and keeps the last copy for offline use.
5. Nothing lost: the recording is written to the phone's storage as it
   happens and kept until its text is delivered (same promise as the
   desktop drafts). A failed or interrupted dictation can be retried from
   the app.
6. Built and installed from the repo: source in the repo, one command on
   butternut builds the APK, one command installs it on the phone.

## Non-goals

- No Nix evaluation on the phone (no Nix-on-Droid, no jinx). The phone
  reads data that Nix produced elsewhere.
- No full QWERTY keyboard: the system/other keyboard stays for typing.
- No Termux configuration, desktop mode, or new phone in this project
  (separate projects; the new-phone research is noted under Later).
- No cloud backend, serverless API or accounts: tailnet + LAN only.
- No streaming text-as-you-speak in v1 (batch, the desktop default).
- No editing the vocabulary from the phone in v1 (read-only from the repo).

## Anti-goals

- Audio or text leaving the user's machines (no third-party APIs).
- An unauthenticated server reachable outside the tailnet/trusted networks
  (the server stays as it is: tailscale0 + trusted networks only).
- A dictation that silently disappears (network drop, app killed, battery).
- Hardcoded hostnames, usernames, colours in the app or its Nix glue
  (everything from the profile / registry / palette).
- Secrets in the public repo (the signing key stays out of git).

## Constraints

- Public repo; flake sees only git-tracked files.
- hazel has a 256 GB disk: no Android SDK / Gradle builds on hazel. Builds
  run on butternut (the user's Android work in routelab already uses
  devenv there).
- The server API is fixed: `POST /inference` multipart (`file` WAV 16 kHz
  mono, `language`, `response_format=json`, `prompt`) -> `{"text": …}`;
  `GET /` is the readiness probe. systemd socket activation means the first
  probe starts the server (model loads while the user speaks): the app
  probes at mic press, not at upload.
- Server names: the phone resolves `butternut` through Tailscale MagicDNS
  (the Android Tailscale app). The profile carries full URLs.
- Android: Snapdragon 888, 8 GB RAM, aarch64. Parakeet int8 is ~640 MB on
  disk; downloaded once on first local use, not bundled in the APK.

## Approaches considered

- **A. Use an existing open-source keyboard as is** (Voice Keyboard by
  Tyraen, F-Droid: custom server, plain http, resends when offline). No
  code, but no local fallback, no shared profile, vocabulary pasted by
  hand. Kept as an optional stopgap the user can install today.
- **B. Fork an open-source keyboard** (Voice Keyboard, WhisperType,
  Voxscribe) and add fallback + profile. Inherits a working IME but also
  someone else's codebase and decisions.
- **C. Our own small Kotlin keyboard (chosen).** Shaped to this fleet, uses
  the laptops' model, and is the home for later phone integrations. Most
  work; the repo takes on the Android build and signing.
- Expo / React Native rejected: an input method has to be a native
  `InputMethodService`; a JS layer adds weight without saving work.

## Design (decided)

### App

- Kotlin, single module, Jetpack Compose for UI, min SDK 31 (Android 12;
  the phone runs a newer Android), target the current SDK of the pinned
  nixpkgs `androidenv`.
- `InputMethodService` with a small panel (not a key grid):
  - big mic button: tap to start, tap to stop (latch, the common phone
    gesture); while recording: timer, input level, which engine will
    transcribe ("butternut" / "on phone");
  - after stop: "Transcribing…", then the text is committed with
    `InputConnection.commitText`, plus a trailing space (desktop
    `appendSpace`);
  - cancel button (discard the recording), switch-keyboard button
    (`switchToPreviousInputMethod`), a drafts button when undelivered
    drafts exist.
- Engine choice once per session, at mic press: probe each profile server's
  `GET /` in parallel (short timeout, e.g. 1.5 s), first answer wins; none:
  local Parakeet (if the language is English and the model is present),
  else the draft is kept as `pending`.
- Pending drafts are never typed into a field on their own (the original
  field is usually gone). When the keyboard or the app opens and a server
  is reachable, pending drafts are transcribed in the foreground and the
  panel shows "2 pending": tap one to insert it into the current field, or
  copy it. No background jobs, WorkManager or notifications in v1.
  *(Builder-check call.)*
- Language: the profile's default language, with a toggle on the panel for
  the profile's other languages (desktop: follows the keyboard layout; the
  phone has no layout, so an explicit toggle). Non-English needs a server.
- Recording: `AudioRecord`, 16 kHz mono PCM 16-bit, written to
  `files/drafts/<id>/audio.wav` as it records (header patched on stop;
  flushed regularly), `meta.json` with status `pending` / `delivered` /
  `cancelled`. Delivered/cancelled drafts pruned after the profile's
  `keepDays`. A drafts screen in the app lists pending ones: retry (and
  copy the text to the clipboard, since the original field may be gone),
  share, delete.
- A launcher activity: settings (profile URL override, model download
  status, "download Parakeet now"), the drafts list, a "test" button that
  probes servers and shows what it sees.

### Phone profile (Nix side)

- One JSON document generated from the NixOS config of the host that serves
  it, e.g.:

  ```json
  {
    "version": 1,
    "servers": ["http://butternut:8178"],
    "defaultLanguage": "en",
    "languages": ["en", "ar"],
    "prompt": "NixOS, Sway, Claude Code, …",
    "keepDays": 7,
    "localModel": {
      "name": "parakeet-tdt-0.6b-v2-int8",
      "url": "http://butternut:<port>/models/<file>",
      "sha256": "…"
    }
  }
  ```

- Values come from existing options where they exist
  (`preferences.dictation.{servers,defaultLanguage,layoutLanguages,prompt,drafts.keepDays}`),
  plus a small `preferences.dictation.phone.*` set for what is
  phone-specific (server URLs as the phone sees them: tailnet names, never
  the `-cable` aliases or `127.0.0.1`).
- Module boundaries (features don't read each other's options): the
  pinned model files (Parakeet, Silero VAD, Whisper) move out of the
  `dictation` feature into flake-level data both features use, e.g.
  `modules/dictation-models.nix` (fetches as functions of `pkgs`), and so
  does the vocabulary (below). The profile is built by `dictation-server`
  from its own options: `preferences.dictation-server.phone.{enable,
  languages, defaultLanguage, keepDays}`, and its server URL defaults to
  `http://${config.networking.hostName}:${port}` (the tailnet name).
  *(Builder-check call.)*
- Served over HTTP on butternut, tailnet/trusted networks only, by the
  `dictation-server` feature (it owns its firewall): the profile plus the
  pinned Parakeet files, straight from their Nix store paths, so the phone
  downloads exactly the bytes the laptops use. No extra service if a
  static route can be added cheaply; otherwise a tiny static server
  (builder's call which).
- The app fetches the profile at app start and at each mic press if older
  than an hour (cheap, tailnet), stores the last good copy, and verifies
  the model's sha256 before using it.
- Model download: as soon as the first profile arrives, on an unmetered
  network only (Wi-Fi), resumable, with a "download now" button in
  settings that overrides the Wi-Fi rule. The profile lists two URLs with
  the same sha256: butternut's copy, then the upstream release URL the Nix
  fetch pins, so the model can be fetched without butternut too. Offline
  fallback therefore works from the first day on Wi-Fi.
  *(Builder-check call.)*
- App updates: the profile carries `appUrl`, pointing at `app.json`
  (`{versionCode, versionName, url, sha256}`), which `phone-app publish`
  rewrites without a redeploy; butternut serves the last APK built there. The app offers "update
  available" and installs through Android's package installer (the user
  confirms; "install unknown apps" granted once). First install: open
  `http://butternut:<port>/` in the phone browser and tap the APK.
  `phone-app install` (adb) stays as the developer path, USB on butternut.
  No phone address in the registry is needed for adb.
  *(Builder-check call; replaces adb as the normal install path.)*

### Vocabulary

- One fleet-wide list as flake-level data, `modules/dictation-vocabulary.nix`
  (like `user.nix`/`theme.nix`), not a per-host option. The `dictation`
  feature's `prompt` defaults to it (hosts may still append), and the phone
  profile's `prompt` is built from it, so a word added once reaches every
  device on the next deploy / profile fetch. Seeded with the fleet's own
  vocabulary (NixOS, Sway, Claude Code, T3 Code, flake, home-manager,
  hazel, butternut, maple, Tailscale, Syncthing, …); the user edits it
  (or asks an agent to). *(Builder-check call.)* Applies to Whisper backends; Parakeet ignores it
  (unless sherpa-onnx hotwords work for this model: builder checks, see
  below).

### Repo layout and build

- App source: `apps/phone/` (Gradle project, Kotlin DSL, wrapper
  committed). Outside `modules/`, so import-tree ignores it.
- `modules/packages/phone-app.nix`: a dev shell / runnable with JDK, Gradle
  and an `androidenv`-composed SDK (pinned build-tools/platform), and two
  commands:
  - `phone-app build` — on butternut (refuses on hazel, like the other
    "no big builds" guards): `./gradlew assembleRelease`;
  - `phone-app install` — `adb install -r` of the last build to a phone
    plugged into butternut by USB (developer path; the normal path is the
    in-app update above);
  - `phone-app publish` — copies the last signed APK where
    `dictation-server` serves it and bumps the profile's `app` entry
    (a state file outside the store, so publishing needs no redeploy).
- Signing: one release keystore generated once on butternut, kept outside
  the repo (e.g. `~/.config/phone-app/release.jks`, backed up in the
  vault). The build reads its path and passwords from the environment / a
  file outside git. A debug-signed build is fine for the first install;
  switching keys later means reinstalling, so the release key comes before
  the user relies on it.
- A fully hermetic Nix derivation for the APK (gradle2nix-style) is not
  required in v1.

## Left to the builder

- Exact Compose layout and styling of the panel; colours follow the
  palette's light/dark scheme of Android (Material You dynamic colours are
  acceptable, no hardcoded hex).
- Probe timeout, profile refresh interval, flush interval (within the
  "nothing lost" goal).
- Whether sherpa-onnx's hotword biasing works with the NeMo TDT model; if
  it does, feed it the vocabulary, if not, document it.
- Static route vs tiny server for the profile and model files.
- Gradle/AGP/Kotlin versions compatible with the pinned `androidenv`.
- Tests: unit tests for engine choice, draft lifecycle and profile parsing;
  a Nix check that the generated profile evaluates and is valid JSON.

## Later (not this project)

- Edit the vocabulary from the phone (needs a write path back to the repo
  or a synced overlay file).
- Battery/metered rules (e.g. prefer local on mobile data), streaming mode.
- Offer the engine as Android's system voice input (`RecognitionService`)
  so other keyboards' mic buttons use it.
- More phone integrations in the same app: fleet status at a glance
  (butternut battery/AC as an ongoing notification, Quick Settings tile or
  widget; butternut publishes a status JSON next to the profile),
  notifications from agents, share-to-fleet.
- Voice diary (own design): record-first, audio kept, encrypted and
  synced; sentence-timed transcripts to browse and replay; re-transcribed
  as better models (Egyptian Arabic) appear; private LLM processing.
- Phone as a standalone workstation: T3 server + Claude Code in Termux /
  Nix-on-Droid for small projects when no other machine is reachable
  (spike first: does T3's server run on Android arm64?).
- The phone hotspot as a declared Wi-Fi profile on the laptops (sops).
- Termux bootstrap from the repo; new phone research (Pixel 8+ for
  GrapheneOS, DisplayPort desktop mode, Android's Linux Terminal VM).
