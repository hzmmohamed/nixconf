# Phone dictation keyboard — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Android dictation keyboard, built from this repo on butternut, that sends audio to butternut's whisper server over the tailnet, falls back to on-phone Parakeet, never loses a recording, and takes its settings from a Nix-generated phone profile.

**Architecture:** Nix side: shared model + vocabulary data at flake level; `dictation-server` builds `profile.json` and serves it, the Parakeet files and published APKs over a tiny static HTTP server (tailnet/trusted only). Phone side: a single-module Kotlin app (`apps/phone/`): pure logic (profile, engine choice, WAV, drafts, session) unit-tested on the JVM; Android glue (recorder, sherpa-onnx, IME panel, activity, updater) checked on the phone. Built with nixpkgs Gradle + an `androidenv` SDK through `nix run .#phone-app -- <cmd>`.

**Tech Stack:** Nix (flake-parts, NixOS modules, darkhttpd 1.17), Kotlin 2.2, AGP 8.13, Gradle 8.14.4 (nixpkgs, no wrapper), JDK 17, Jetpack Compose (BOM), kotlinx.serialization, OkHttp 4 + MockWebServer, sherpa-onnx 1.12.38 AAR, JUnit 4.

**Spec:** `docs/plans/2026-11-22-phone-dictation-keyboard-design.md`

## Global Constraints

- Public repo: no keystore, passwords, tokens or personal data in git.
- No Android SDK/Gradle work on a machine that offloads its builds (hazel); `phone-app build|test` refuse when `/etc/nix/machines` is non-empty unless `--force`.
- Server API is fixed: `POST /inference` multipart (`file` = WAV 16 kHz mono s16le, `language`, `response_format=json`, `prompt`, `temperature=0.0`, `temperature_inc=0.2`) → `{"text": …}`; `GET /` = readiness probe (also starts the socket-activated server).
- Profile and model/APK server: tailnet + trusted networks only (`preferences.trustedNetworks.allowedTCPPorts`), never a public interface; no authentication.
- No hardcoded hostnames/usernames in Nix (`config.networking.hostName`, `config.preferences.user.name`); no hardcoded hex colours in the app (Material dynamic colour / theme defaults).
- Features don't read each other's options; shared things are flake-level data.
- Model: Parakeet TDT 0.6B v2 int8 (sherpa-onnx export), `model_type = "nemo_transducer"`, `greedy_search`, English only; same files and hashes as the laptops.
- minSdk 31, compileSdk/targetSdk 36, build-tools 36.0.0, ABI arm64-v8a only.
- applicationId `nixconf.phone`, app label "Nixconf" (named for the setup, not dictation).
- Profile `version` = 1; app refuses a profile with a higher major version (keeps the cached one).
- Draft statuses: `pending` / `delivered` / `cancelled`; delivered + cancelled pruned after profile `keepDays` (default 7); pending never pruned.
- Repo rules: `git add -N` new files before eval; `just check` (or raw: `nix fmt`, deadnix, `nix eval` per host) before handing back; agents never run `nixos-rebuild`/`deploy`/`sops`/`git push`. Commits only once the user has OK'd committing this work; otherwise stop at "staged".

## Review Focus

1. **Server reachable at press, fails at upload** (butternut busy, Wi-Fi drops mid-session, 500, timeout) → the session falls back to local Parakeet (English) or keeps the draft `pending`; text never lost. Test in Task 6.
2. **App killed / phone reboots mid-recording** → the WAV whose header was never patched is still readable; the draft shows as `pending` with its audio. Test in Task 4 (`WavWriter.repair`) and Task 4 (`DraftStore.load` repairs).
3. **Focused field changed while transcribing** (user switched app, IME hidden) → text is not typed into the new field; the draft stays `pending` with its text, offered on the panel. Test in Task 6.
4. **No profile ever fetched** (first launch off the tailnet) → the keyboard still records and keeps drafts, panel says "No profile yet"; nothing crashes on a null profile. Test in Task 3 and Task 6.
5. **Model download interrupted / hash mismatch / disk full** → partial `.part` file is never loaded; the next attempt resumes; a mismatch deletes and reports. Test in Task 5.

---

## File map

```
modules/dictation-models.nix          flake.dictationModels = pkgs: { parakeet; whisperSmall; sileroVadOnnx; }
modules/dictation-vocabulary.nix      flake.dictationVocabulary = [ "NixOS" … ]
modules/nixos/features/dictation.nix  uses both (models moved out; prompt default from vocabulary)
modules/nixos/features/dictation-server.nix   + preferences.dictation-server.phone.*, profile.json, darkhttpd unit
modules/nixos/features/dictation/phone-profile.sh   assembles profile.json (hashes files)
modules/nixpkgs-config.nix            + android_sdk.accept_license (user consent, Task 3)
modules/packages/phone-app.nix        perSystem packages.phone-app (build|test|install|publish)
modules/packages/phone-app.sh         the script body
modules/checks.nix                    + checks.phone-profile
apps/phone/settings.gradle.kts, build.gradle.kts, gradle.properties, app/build.gradle.kts
apps/phone/app/src/main/AndroidManifest.xml, res/xml/method.xml, res/values/strings.xml
apps/phone/app/src/main/java/nixconf/phone/
  profile/Profile.kt, profile/ProfileStore.kt
  engine/EngineChooser.kt, engine/WhisperClient.kt, engine/LocalEngine.kt
  audio/WavWriter.kt, audio/Recorder.kt
  drafts/DraftStore.kt
  model/ModelDownloader.kt
  session/DictationSession.kt
  ime/DictationIme.kt, ime/Panel.kt
  ui/MainActivity.kt
  update/Updater.kt
apps/phone/app/src/test/java/nixconf/phone/…   JVM unit tests mirroring the above
```

---

### Task 1: Shared models and fleet vocabulary (Nix)

**Files:**
- Create: `modules/dictation-models.nix`, `modules/dictation-vocabulary.nix`
- Modify: `modules/nixos/features/dictation.nix` (the `parakeet`, `whisperSmall`, `sileroVad` let-bindings at ~90–145 move out; `prompt` default)

**Interfaces:**
- Produces: `self.dictationModels :: pkgs -> { parakeet :: drv (dir with encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt); parakeetArchive :: { url; hash; } ; whisperSmall :: drv; sileroVadOnnx :: drv }` (same urls/hashes as today). `self.dictationVocabulary :: [str]`.

> `dictation.nix` has uncommitted changes from another session in the main tree. Do this task in a worktree and rebase onto that work once it is committed; if it is still uncommitted when you start, stop and ask.

- [ ] **Step 1: Record the current dictate config drv** — `nix eval --raw .#nixosConfigurations.hazel.config.system.build.toplevel.drvPath` (keep the value).
- [ ] **Step 2: Create `dictation-models.nix`** with the three fetches moved verbatim plus `parakeetArchive = { url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2"; hash = "sha256-b8RCa1SqVJoAGbinW43qWRZOcXkKN6xWoEWtV/kV9xQ="; }` (the `parakeet` src uses it).
- [ ] **Step 3: Create `dictation-vocabulary.nix`**: `flake.dictationVocabulary = ["NixOS" "Nix" "flake" "home-manager" "Sway" "Claude Code" "T3 Code" "Tailscale" "Syncthing" "KeePassXC" "hazel" "butternut" "maple" "peacelily" "fern" "routelab" "QGIS" "Parakeet" "Whisper"];` with a header comment: fleet-wide, feeds the desktop Whisper prompt and the phone profile.
- [ ] **Step 4: Rewire `dictation.nix`**: `models = self.dictationModels pkgs;` and use `models.parakeet` etc.; `prompt` default becomes `lib.concatStringsSep ", " self.dictationVocabulary + "."` (description: hosts may override/extend).
- [ ] **Step 5: Verify** — `git add -N modules/dictation-*.nix`; `nix eval .#nixosConfigurations.hazel.config.preferences.dictation.prompt` prints a string starting `"NixOS, Nix, flake`; `just eval hazel && just eval butternut` OK. Model pins unchanged: `nix derivation show <new hazel drvPath> --recursive | rg 'parakeet-tdt|ggml-small|silero_vad'` lists the same output paths as for the Step 1 drvPath.
- [ ] **Step 6: Commit** — `git add modules/dictation-models.nix modules/dictation-vocabulary.nix modules/nixos/features/dictation.nix && git commit -m "Dictation: shared model pins and fleet vocabulary at flake level"`

### Task 2: Phone profile and its static server (Nix)

**Files:**
- Modify: `modules/nixos/features/dictation-server.nix`
- Create: `modules/nixos/features/dictation/phone-profile.sh`
- Modify: `modules/checks.nix`
- Modify: `modules/nixos/hosts/butternut/configuration.nix` (`preferences.dictation-server.phone.enable = true;`)

**Interfaces:**
- Consumes: `self.dictationModels`, `self.dictationVocabulary` (Task 1).
- Produces (the app relies on these exactly):
  - `GET http://<host>:<phone.port>/profile.json`:
    ```json
    {"version":1,
     "servers":["http://butternut:8178"],
     "defaultLanguage":"en","languages":["en","ar"],
     "prompt":"NixOS, Nix, …","keepDays":7,
     "localModel":{"name":"parakeet-tdt-0.6b-v2-int8","language":"en",
       "files":[{"name":"encoder.int8.onnx","size":123,"sha256":"<hex>",
                 "url":"http://butternut:8180/models/parakeet/encoder.int8.onnx"}, …4 files],
       "archive":{"url":"https://github.com/…/…-int8.tar.bz2","sha256":"<hex>"}},
     "appUrl":"http://butternut:8180/app.json"}
    ```
  - `GET /models/parakeet/<file>` (the store files), `GET /app.json` and `GET /app/<apk>` (written by `phone-app publish`, Task 8).
  - Options `preferences.dictation-server.phone.{enable (bool, false), port (port, 8180), servers ([str], default ["http://${config.networking.hostName}:${toString cfg.port}"]), defaultLanguage ("en"), languages (["en" "ar"]), keepDays (7)}`.
  - State dir `/var/lib/phone-profile` (`app/` owned by `config.preferences.user.name`, mode 0755).

- [ ] **Step 1: Write the check first** — in `modules/checks.nix` add `checks.phone-profile`: build butternut's `config.preferences.dictation-server.phone.profile` (expose the derivation as a read-only option `phone.profile`) and run `jq -e '.version == 1 and (.servers|length) > 0 and (.localModel.files|length) == 4 and all(.localModel.files[]; .sha256|test("^[0-9a-f]{64}$"))'` on it.
- [ ] **Step 2: Run it, expect failure** — `nix build --no-link .#checks.x86_64-linux.phone-profile` → error: option `phone` does not exist.
- [ ] **Step 3: Implement** — options above; `profile` = `pkgs.runCommand "phone-profile.json" { nativeBuildInputs = [jq coreutils]; base = builtins.toJSON {...}; } "bash ${./dictation/phone-profile.sh}"` where the script adds `files[]` (name, size via `stat -c %s`, `sha256sum`) for the four Parakeet files and the archive hex (`nix-hash --to-base16` of the SRI, done in Nix with `builtins.convertHash`). Base URL `http://${config.networking.hostName}:${toString phone.port}`. Serving: `systemd.services.phone-profile` running `darkhttpd /var/lib/phone-profile --port <port> --no-listing --mimetypes <file mapping .apk to application/vnd.android.package-archive>`, `StateDirectory=phone-profile`, `ExecStartPre` (with `+` prefix, root) that (re)links `profile.json` and `models/parakeet/*` to the store paths; `systemd.tmpfiles` creates `app/` owned by the user; `preferences.trustedNetworks.allowedTCPPorts = [phone.port]`. Header comment in the feature's existing style.
- [ ] **Step 4: Run the check, expect PASS**; `just eval butternut && just eval hazel` OK; `cat $(nix build --no-link --print-out-paths .#checks…)`-style inspection shows `"servers":["http://butternut:8178"]`.
- [ ] **Step 5: Commit** — `git add -N` then `git commit -m "dictation-server: phone profile, Parakeet files and APKs over HTTP"`

### Task 3: Android toolchain, app skeleton, profile parsing

**Files:**
- Modify: `modules/nixpkgs-config.nix` (`config.android_sdk.accept_license = true;`; user agreed 2026-11-22). Precedent: routelab-monorepo's `flake.nix` uses the same flag and the same `androidenv.composeAndroidPackages` call (platform 36, build-tools 36.0.0, `ORG_GRADLE_PROJECT_android.aapt2FromMavenOverride`) for its `mobile-ci-image`; mirror it.
- Create: `modules/packages/phone-app.nix`, `modules/packages/phone-app.sh`
- Create: `apps/phone/{settings.gradle.kts,build.gradle.kts,gradle.properties,.gitignore}`, `apps/phone/app/build.gradle.kts`, `AndroidManifest.xml`, `res/values/strings.xml`
- Create: `apps/phone/app/src/main/java/nixconf/phone/profile/{Profile.kt,ProfileStore.kt}`
- Test: `apps/phone/app/src/test/java/nixconf/phone/profile/ProfileTest.kt`

**Interfaces:**
- Produces: `nix run .#phone-app -- build [--release] [--force] | test [--force] | install | publish` (install/publish in Tasks 8). Env given to Gradle: `ANDROID_HOME`, `JAVA_HOME` (jdk17), `-Pandroid.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/36.0.0/aapt2` (Maven's aapt2 does not run on NixOS), `-PsherpaAar=<store path>` (fetchurl `https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.38/sherpa-onnx-1.12.38.aar`, `sha256-elalyZxcHY7XeqdrrZ8PMGhSQS6xF9WP7+BEvYzbGKY=`). Gradle runs with `--project-dir apps/phone` from the repo root (found via `git rev-parse --show-toplevel`). SDK: `androidenv.composeAndroidPackages { platformVersions = ["36"]; buildToolsVersions = ["36.0.0"]; includeNDK = false; includeEmulator = false; }` (evaluates in the pinned nixpkgs).
- Produces (Kotlin): `@Serializable data class Profile(version:Int, servers:List<String>, defaultLanguage:String, languages:List<String>, prompt:String, keepDays:Int, localModel:LocalModel?, appUrl:String?)`, `LocalModel(name, language, files:List<ModelFile>, archive:Archive?)`, `ModelFile(name, size:Long, sha256, url)`, `Archive(url, sha256)`; `fun parseProfile(json:String): Profile` (ignores unknown keys; throws `UnsupportedProfile` if `version > 1`). `class ProfileStore(dir: File, fetch: (String) -> String, clock: () -> Long)` with `fun cached(): Profile?`, `fun refreshIfStale(url: String, maxAgeMs: Long = 3_600_000): Profile?` (on failure returns cached; never throws), default URL `http://butternut:8180/profile.json` overridable in settings.

- [ ] **Step 1: Write `ProfileTest`**: `parses_full_profile` (the JSON from Task 2 → `servers == listOf("http://butternut:8178")`, `localModel!!.files.size == 4`); `ignores_unknown_keys`; `rejects_future_version` (`version: 2` → `UnsupportedProfile`); `store_returns_cache_when_fetch_fails` (fetch throws `IOException` → previous profile); `store_without_cache_and_no_network_returns_null`; `store_skips_fetch_when_fresh` (fetch called once across two calls within an hour).
- [ ] **Step 2: Scaffold Gradle + package**, `.gitignore` (`build/`, `.gradle/`, `local.properties`), `git add -N`; run `nix run .#phone-app -- test` → tests compile-fail (no `Profile`).
- [ ] **Step 3: Implement `Profile.kt` and `ProfileStore.kt`** (cache = `profile.json` + mtime in `dir`).
- [ ] **Step 4: `nix run .#phone-app -- test` → PASS**; `nix run .#phone-app -- build` produces `apps/phone/app/build/outputs/apk/debug/app-debug.apk` (an app with an empty launcher activity); on a machine with `/etc/nix/machines` non-empty, `build` exits 2 with "this machine offloads its builds; run on the builder or pass --force".
- [ ] **Step 5: Commit** — "Phone app: Android toolchain from nixpkgs, skeleton, profile parsing"

### Task 4: WAV files and drafts

**Files:**
- Create: `audio/WavWriter.kt`, `drafts/DraftStore.kt`
- Test: `audio/WavWriterTest.kt`, `drafts/DraftStoreTest.kt`

**Interfaces:**
- Produces: `class WavWriter(file: File, sampleRate: Int = 16000)` : `write(samples: ShortArray, n: Int)`, `flush()` (fsync), `close()` (patches RIFF/data sizes); `object WavFiles { fun repair(file: File): Boolean; fun readSamples(file: File): ShortArray }` (repair recomputes sizes from file length when the header says 0).
- `enum DraftStatus { PENDING, DELIVERED, CANCELLED }`; `data class Draft(id:String, dir:File, status:DraftStatus, createdMs:Long, language:String, engine:String?, text:String?, error:String?)`; `class DraftStore(root: File, clock: () -> Long)`: `create(language): Draft` (id `yyyyMMdd_HHmmss-xxxx`, dir with `audio.wav`, `meta.json`), `update(draft)`, `load(id)` (repairs the WAV if status is pending), `pending(): List<Draft>` (oldest first), `prune(keepDays: Int)`.

- [ ] **Step 1: Tests**: `header_sizes_patched_on_close` (1 s of samples → data size 32000, RIFF size 32036); `unpatched_file_is_repaired` (write 16000 samples, flush, no close → `repair` true, `readSamples().size == 16000`); `create_then_pending_lists_it`; `delivered_and_cancelled_pruned_after_keepDays_pending_kept` (clock moved 8 days); `meta_survives_reload` (text, engine, error round-trip).
- [ ] **Step 2: Run** `nix run .#phone-app -- test` → FAIL (classes missing).
- [ ] **Step 3: Implement** (meta.json via kotlinx.serialization; writes go to `meta.json.tmp` + rename).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — "Phone app: crash-safe WAV drafts"

### Task 5: Whisper client, engine choice, model download

**Files:**
- Create: `engine/WhisperClient.kt`, `engine/EngineChooser.kt`, `model/ModelDownloader.kt`
- Test: `engine/WhisperClientTest.kt`, `engine/EngineChooserTest.kt`, `model/ModelDownloaderTest.kt` (MockWebServer)

**Interfaces:**
- `class WhisperClient(http: OkHttpClient)`: `suspend fun probe(url: String, timeoutMs: Long = 1500): Boolean` (`GET /` 2xx); `suspend fun transcribe(url: String, wav: File, language: String, prompt: String): String` (fields as in Global Constraints; 120 s timeout; throws `IOException` on non-2xx / missing `text`).
- `sealed interface Engine { data class Remote(val url: String): Engine; object Local: Engine; object Unavailable: Engine }`; `suspend fun chooseEngine(servers: List<String>, language: String, localReady: Boolean, localLanguage: String, probe: suspend (String) -> Boolean): Engine` — probes all in parallel, the **first in list order** among those that answered wins (same as desktop); none → `Local` if `localReady && language == localLanguage`, else `Unavailable`.
- `class ModelDownloader(http, dir: File, isUnmetered: () -> Boolean)`: `fun isReady(model: LocalModel): Boolean` (all files present with recorded hashes), `suspend fun download(model: LocalModel, force: Boolean = false, progress: (Long, Long) -> Unit): Result<File>` — per file: skip if verified; `<name>.part` with `Range: bytes=<len>-` resume; sha256 verify then rename; mismatch deletes `.part` and fails; refuses (`NotOnWifi`) when `!force && !isUnmetered()`; falls back to `archive` (tar.bz2 via commons-compress, verify archive sha256, extract the four files) when every per-file URL fails.

- [ ] **Step 1: Tests**: `probe_true_on_200_false_on_timeout`; `transcribe_sends_fields_and_parses_text` (assert multipart has `language=en`, `response_format=json`, `prompt`, a `file` part); `transcribe_throws_on_500`; chooser: `first_listed_reachable_wins` (both up, second answers faster → first), `falls_back_to_local_for_english`, `unavailable_for_arabic_without_server`, `unavailable_when_local_not_ready`; downloader: `resumes_partial_file` (server honours Range; final hash ok), `hash_mismatch_deletes_part_and_fails`, `refuses_on_metered_unless_forced`, `part_file_never_counts_as_ready`, `falls_back_to_archive`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — "Phone app: whisper client, engine choice, verified model download"

### Task 6: Dictation session (orchestration)

**Files:**
- Create: `session/DictationSession.kt`
- Test: `session/DictationSessionTest.kt` (fakes for recorder, engines, editor)

**Interfaces:**
- Consumes: `chooseEngine`, `WhisperClient.transcribe`, `DraftStore`, `Profile`.
- Produces:
  ```kotlin
  interface AudioSource { fun start(out: WavWriter); fun stop(); val level: StateFlow<Float> }
  interface LocalTranscriber { val ready: Boolean; fun transcribe(wav: File): String }
  interface EditorTarget { val token: String?; fun commit(text: String): Boolean }  // token = package + field id of the focused editor
  sealed interface SessionState { object Idle; data class Recording(val engine: Engine, val startedMs: Long); data class Transcribing(val engine: Engine); data class Done(val text: String); data class Kept(val draft: Draft, val reason: String) }
  class DictationSession(profile: () -> Profile?, drafts: DraftStore, audio: AudioSource, remote: WhisperClient, local: LocalTranscriber, probe: suspend (String) -> Boolean, scope: CoroutineScope)
    val state: StateFlow<SessionState>
    fun start(language: String, target: EditorTarget)   // chooses engine (null profile → servers = []), creates draft, starts audio
    fun stop()                                          // close WAV, transcribe, deliver
    fun cancel()                                        // draft → CANCELLED, nothing committed
    suspend fun retry(draft: Draft): Draft              // re-choose engine, transcribe; text stored, status stays PENDING until delivered
    fun deliver(draft: Draft, target: EditorTarget): Boolean  // commit + " " , status DELIVERED
  ```
  Delivery rule: commit `text + " "` only if `target.token` still equals the token captured at `start`; otherwise the draft stays `PENDING` with its text (state `Kept(reason = "field changed")`). Remote failure → `Local` if eligible, else `Kept(reason = "no server reachable")`. Empty transcript → `Kept(reason = "nothing heard")`.

- [ ] **Step 1: Tests**: `remote_text_committed_and_draft_delivered`; `remote_fails_midway_falls_back_to_local` (Review Focus 1); `remote_fails_arabic_keeps_pending`; `field_changed_keeps_pending_with_text` (Review Focus 3); `null_profile_records_and_keeps_draft` (Review Focus 4); `cancel_marks_cancelled_commits_nothing`; `retry_fills_text_without_delivering`; `appends_single_space`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** (kotlinx-coroutines-test for the tests).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — "Phone app: dictation session with fallback and safe delivery"

### Task 7: Android glue — recorder, sherpa-onnx, keyboard panel, app screen

**Files:**
- Create: `audio/Recorder.kt` (implements `AudioSource`: `AudioRecord`, `VOICE_RECOGNITION`, 16 kHz mono PCM16, flush every 2 s), `engine/LocalEngine.kt` (implements `LocalTranscriber`: `OfflineRecognizer` with `OfflineTransducerModelConfig(encoder, decoder, joiner)`, `tokens`, `modelType = "nemo_transducer"`, `decodingMethod = "greedy_search"`, `numThreads = 4`; loaded lazily on first use, released after 5 min idle), `ime/DictationIme.kt`, `ime/Panel.kt`, `ui/MainActivity.kt`, `res/xml/method.xml`, manifest entries (`BIND_INPUT_METHOD` service, `RECORD_AUDIO`, `INTERNET`, `ACCESS_NETWORK_STATE`, `android:usesCleartextTraffic="true"`: the app only talks to tailnet/LAN URLs from the profile).

**Interfaces:**
- Consumes: everything above.
- `DictationIme : InputMethodService` hosts a `ComposeView`; set `ViewTreeLifecycleOwner`/`SavedStateRegistryOwner` on the window decor view (Compose in an IME needs them). `EditorTarget.token` = `"${editorInfo.packageName}/${editorInfo.fieldId}"`, refreshed in `onStartInput`.
- Panel (from the spec): big mic (tap start / tap stop), timer, level bar, engine label ("butternut" = host of the remote URL / "on phone" / "no server"), language toggle over `profile.languages`, cancel, switch-keyboard (`switchToPreviousInputMethod()`), "N pending" chip → list: tap inserts via `deliver`, long-press copies. "No profile yet" line when `cached()` is null. Mic permission missing → the mic button opens `MainActivity` (an IME cannot request permissions).
- `MainActivity`: profile URL setting (default `http://butternut:8180/profile.json`), "Test" (probe each server, show results), model status + "Download now" (force), drafts list (retry, copy, share audio, delete), "Enable keyboard" shortcut to `Settings.ACTION_INPUT_METHOD_SETTINGS`, permission request.
- On IME show and activity resume: `refreshIfStale`; if a server is reachable, `retry` pending drafts (foreground, no background jobs); `drafts.prune(profile.keepDays)`; kick `ModelDownloader.download(force = false)` if not ready.

- [ ] **Step 1: Implement** the files above; `nix run .#phone-app -- test` still PASS; `nix run .#phone-app -- build` OK.
- [ ] **Step 2: Phone check (user, after Task 2 is deployed on butternut)** — `nix run .#phone-app -- install` with the phone on USB; enable the keyboard; in a notes app: dictate a sentence with butternut up → text appears, label "butternut"; turn Wi-Fi + data off → label "on phone" (after the model downloaded on Wi-Fi), text appears; switch app mid-transcription → nothing typed there, "1 pending" offered; kill the app while recording → draft listed with audio in MainActivity.
- [ ] **Step 3: Commit** — "Phone app: keyboard panel, recorder, on-phone Parakeet, app screen"

### Task 8: Signing, publishing, in-app update

**Files:**
- Create: `update/Updater.kt`, `update/UpdaterTest.kt`
- Modify: `modules/packages/phone-app.sh` (`build --release`, `install`, `publish`), `apps/phone/app/build.gradle.kts` (release signing from `-P` props)

**Interfaces:**
- Signing inputs (outside git): `~/.config/phone-app/release.jks` and `~/.config/phone-app/signing.properties` (`storePassword`, `keyAlias`, `keyPassword`); `build --release` fails with the `keytool` command to create them if missing. `versionCode` = `git rev-list --count HEAD`, `versionName` = short rev (+`-dirty`), passed as `-P`.
- `install`: `adb install -r` the newest APK (release if present, else debug).
- `publish`: copy the release APK to `/var/lib/phone-profile/app/nixconf-phone-<versionCode>.apk`, write `/var/lib/phone-profile/app.json` = `{"versionCode":N,"versionName":"…","url":"<base>/app/nixconf-phone-N.apk","sha256":"<hex>"}` atomically; keep the last 3 APKs. Base URL read from the served `profile.json`'s `appUrl` origin.
- `class Updater(http, dir, installer: (File) -> Unit)`: `suspend fun check(appUrl: String, currentVersionCode: Int): AppRelease?` (newer only), `suspend fun downloadVerified(r: AppRelease): File` (sha256), install via `PackageInstaller` session (`REQUEST_INSTALL_PACKAGES` in the manifest; MainActivity shows "Update available").

- [ ] **Step 1: Tests**: `newer_release_offered`, `same_or_older_ignored`, `bad_hash_rejected`.
- [ ] **Step 2: Run → FAIL. Step 3: Implement. Step 4: Run → PASS**; `nix run .#phone-app -- build --release` without a keystore prints the `keytool -genkeypair -v -keystore ~/.config/phone-app/release.jks -keyalg RSA -keysize 4096 -validity 36500 -alias nixconf-phone` hint and exits 1.
- [ ] **Step 5: Commit** — "Phone app: release signing, publish to butternut, in-app update"

### Task 9: Documentation and user actions

**Files:**
- Modify: `docs/plans/2026-11-17-user-actions.md` (paste-ready steps), `ARCHITECTURE.md` (dictation-server phone profile; `apps/phone`), `CLAUDE.md` Layout block (`apps/phone/  Android companion app (Gradle; nix run .#phone-app)`), design doc status → "Approved 2026-11-22".

- [ ] **Step 1: User actions** (fish-safe, one block each): deploy butternut (`just deploy butternut`); check `curl -s http://butternut:8180/profile.json | jq .servers`; create the keystore (keytool line from Task 8) and back it up in the vault; on the phone: enable USB debugging once, `nix run .#phone-app -- build --release && nix run .#phone-app -- install`; enable the keyboard, grant the mic; first Wi-Fi session downloads the model (~640 MB); later updates: `nix run .#phone-app -- build --release && nix run .#phone-app -- publish`, then "Update" in the app.
- [ ] **Step 2: Verify** — `just check` (or the raw commands) passes; `nix build --no-link .#checks.x86_64-linux.phone-profile` passes.
- [ ] **Step 3: Commit** — "Docs: phone companion app"
