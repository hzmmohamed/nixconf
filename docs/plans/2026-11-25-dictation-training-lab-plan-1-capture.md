# Dictation training lab, plan 1 of 6: Capture

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every new dictation draft, on the phone and on the laptops, records which app it went into, its privacy tier (work/personal) and Whisper's confidence. The user can see and flip the tier while dictating, and the laptops' Whisper prompt finally carries the fleet vocabulary. No new service.

**Architecture:** Tier is computed at record time from the target app (Android package / Sway `app_id`) against a public work list, defaulting to personal, with a one-draft override (Pollen panel chip; `dictate tier`). Whisper requests switch from `json` to `verbose_json`, and the per-segment and per-word confidences are stored next to each segment's text. Later plans (hub, suspects, game, Claude + apply, Pollen screen) read these fields.

**Tech Stack:** Python 3 stdlib (`dictate-stream.py`, `unittest`), bash (`dictate.sh`), Nix (dictation, dictation-server features, flake checks), Kotlin/Compose (Pollen, JUnit + MockWebServer).

**Spec:** `docs/plans/2026-11-25-dictation-training-lab-design.md` (§3 tiers, §5.2 capture, §5.6, §5.8 a, §6 phase 1).

**Deviations from the spec:** the desktop override is `dictate tier work|personal|auto` (one-shot, plus two `dictate menu` entries) instead of `dictate --work/--personal`: sessions start from a key bound to `dictate press`, so a flag has nowhere to go. The spec's `model` field is dropped: whisper-server does not report its model, and `backend` is already recorded. The design doc is updated to match.

**Plan series:** 1 Capture (this) · 2 Hub (inbox, uploads, retention) · 3 Suspects (heuristics, agent-prompt mining, CLI census) · 4 Game page · 5 Claude pass + apply (`private.json`) · 6 Pollen screen, open-weight pass, dataset. Each is written when the previous one merges.

## Global Constraints

- Tier values are exactly `"work"` and `"personal"`. A draft with no tier, or any other value, counts as `"personal"` everywhere (fail-closed).
- Unlisted apps, empty app ids and browsers are `"personal"`. Matching is exact on the lowercased app id (desktop) or the exact package name (phone). No prefix or fuzzy matching.
- An override applies to one draft only, then the guess returns.
- Incognito fields: unchanged behaviour (draft deleted on delivery). The panel shows no chip there.
- No new key bindings (user rule). The desktop override is a `dictate` subcommand and an entry in the existing `dictate menu`.
- `prompt_sha` / `promptSha`: the first 12 hex chars of SHA-256 of the configured prompt (the vocabulary part only, without the per-segment context), UTF-8.
- `origin`: `"phone"` on the phone; the hostname (`socket.gethostname()`) on the laptops. Never hardcode hostnames.
- Confidence fields are optional everywhere: Parakeet, the local engine and a failed parse store none, and nothing breaks.
- Public repo: test fixtures use invented sentences only. Never copy text or audio from `~/.local/state/dictation`.
- New files: `git add -N <file>` before any Nix eval (flakes only see tracked files).
- Before handing back: `just check` (raw: see `justfile`) and `nix run .#phone-app -- test` (butternut).

## Review Focus

- An old draft (meta.json written before this change) on either side must still load, list, recover and prune, and reads as `personal`.
- Whisper answers without `segments`/`words` (older server, the local whisper-server fallback, an error body) must still yield the text, with no confidence stored and no exception.
- The Sway tree has no focused window (or `swaymsg` fails) at key press: `app` is `""` and the tier is `personal`, and recording starts as fast as before (the lookup must not delay the recorder).
- A `dictate tier work` override followed by a cancelled or empty session must not leak into the next session.
- On the phone, switching fields between apps mid-panel resets a flipped chip to the new app's guess, but a flip made just before recording sticks to that recording.

---

### Task 1: Desktop prompt default and work list (Nix)

**Files:**
- Modify: `modules/nixos/features/dictation.nix` (option `prompt` at ~line 423; `streamConfig` at ~line 228; new option `workApps`)

**Interfaces:**
- Produces: `streamConfig` keys `prompt` (now defaults to the vocabulary) and `work_apps: [str]` (lowercased), consumed by Task 2.

- [ ] **Step 1: Default `preferences.dictation.prompt` to the fleet vocabulary.** Same expression and `defaultText` as `preferences.dictation-server.phone.prompt` (`lib.concatStringsSep ", " self.dictationVocabulary + "."`). Check the module's header has `self` in scope; add it if not.
- [ ] **Step 2: Add `preferences.dictation.workApps`**: `listOf str`, description "Sway app_ids whose dictation is work tier (Claude may analyse it); everything else is personal." Default: `["kitty" "codium" "com.t3tools.t3code"]`. Before committing, verify the real ids on butternut with the windows open: `swaymsg -t get_tree | jq -r '.. | .app_id? // empty' | sort -u` (VSCodium and T3 ids may differ). Use what it prints.
- [ ] **Step 3: Add `work_apps = map lib.toLower cfg.workApps;` to `streamConfig`.**
- [ ] **Step 4: Verify.** Run `nix eval --raw .#nixosConfigurations.hazel.config.system.build.toplevel.drvPath` and the same for butternut. Expected: both print a `.drv` path. Then `nix eval --raw .#nixosConfigurations.hazel.config.preferences.dictation.prompt`. Expected: starts `NixOS, Nix, flake,`.
- [ ] **Step 5: Commit** `dictation: laptops send the fleet vocabulary as the Whisper prompt; workApps list`.

### Task 2: Tier, app and confidence in desktop drafts (`dictate-stream`)

**Files:**
- Modify: `modules/nixos/features/dictation/dictate-stream.py`
- Create: `modules/nixos/features/dictation/tests/test_capture.py`
- Modify: `modules/nixos/features/dictation.nix` (add a flake check, as `agent-env.nix:121-127` does)

**Interfaces:**
- Consumes: `CFG["work_apps"]`, `CFG["prompt"]` (Task 1).
- Produces (module-level in `dictate-stream.py`):
  - `tier_for(app: str, work_apps: list[str], override: str | None) -> str`: `override` wins if it is `"work"`/`"personal"`; otherwise `"work"` iff `app.lower()` is in `work_apps`; otherwise `"personal"`.
  - `prompt_sha(prompt: str) -> str`: 12 hex chars, as in Global Constraints.
  - `parse_inference(answer: dict) -> tuple[str, dict | None]`: the text, plus `conf` = `{"avg_logprob": float (min over segments), "no_speech_prob": float (max), "words": [{"w": str, "p": float, "start": float, "end": float}], "lang": str, "lang_p": float}`. It returns `conf = None` when `segments` is missing or empty. `lang`/`lang_p` come from `detected_language`/`detected_language_probability` when present.
  - `Backends.transcribe(samples, prompt="") -> tuple[str, dict | None]` (was `str`). `_local` returns `(text, None)`.
  - Draft meta gains `app: str`, `tier: str`, `origin: str`, `prompt_sha: str`. A `commits.jsonl` line gains `conf` only when not None.
  - `dictate-stream record --tier {work,personal}`.
  - The overlay message gains `"tier"`.

Verified response shape (whisper.cpp server on butternut, 2026-11-25, `response_format=verbose_json`): top-level `task, language, duration, text, segments, detected_language, detected_language_probability, language_probabilities`. A segment has `id, text, start, end, tokens, words, temperature, avg_logprob, no_speech_prob`. A word has `word, start, end, t_dtw, probability`. There is no `compression_ratio`.

- [ ] **Step 1: Write the failing tests** in `tests/test_capture.py`. Load the script with `importlib.util.spec_from_file_location("dictate_stream", <path>)` after setting `DICTATE_CONFIG` to a temp JSON (`journal_dir` = temp dir, `prompt` = `"NixOS, Sway."`, `work_apps` = `["kitty"]`, plus the keys `load_config` and module-level code read: `default_lang`, `mode`, `workers`, `bin`, `overlay`) and `XDG_RUNTIME_DIR` = temp dir. Tests:
  - `test_tier_for`: `tier_for("kitty", ["kitty"], None) == "work"`; `tier_for("Kitty", ["kitty"], None) == "work"`; `tier_for("firefox", ["kitty"], None) == "personal"`; `tier_for("", ["kitty"], None) == "personal"`; `tier_for("firefox", ["kitty"], "work") == "work"`; `tier_for("kitty", ["kitty"], "personal") == "personal"`; `tier_for("kitty", ["kitty"], "bogus") == "work"`.
  - `test_prompt_sha`: `prompt_sha("NixOS, Sway.") == hashlib.sha256(b"NixOS, Sway.").hexdigest()[:12]`.
  - `test_parse_inference_verbose`: a fixture with two segments (`avg_logprob` -0.2 and -0.9; `no_speech_prob` 0.01 and 0.3; two words each with invented text) gives `text == fixture["text"]`, `conf["avg_logprob"] == -0.9`, `conf["no_speech_prob"] == 0.3`, `len(conf["words"]) == 4`, `conf["words"][0] == {"w": ..., "p": ..., "start": ..., "end": ...}`, `conf["lang"] == "en"`.
  - `test_parse_inference_plain`: `parse_inference({"text": "hello"}) == ("hello", None)`.
  - `test_draft_meta_has_tier_fields`: `Draft.create(..., app="kitty", tier="work")` writes meta.json with `app == "kitty"`, `tier == "work"`, `origin == socket.gethostname()`, `prompt_sha == prompt_sha(CFG["prompt"])`.
  - `test_old_draft_loads_as_personal`: a draft dir whose meta.json has no `tier` → `Draft.load(path).meta.get("tier", "personal") == "personal"`, and `list_drafts()` still includes it.
- [ ] **Step 2: Run them and see them fail.** Run `nix shell --inputs-from . nixpkgs#python3Packages.numpy nixpkgs#python3Packages.onnxruntime nixpkgs#python3 -c python3 -m unittest discover -s modules/nixos/features/dictation/tests -v`. Expected: FAIL (`tier_for` not defined). If that `nix shell` form won't pull the libraries in, use `python3.withPackages` via `nix shell --impure --expr`.
- [ ] **Step 3: Implement.**
  - Add `tier_for`, `prompt_sha` and `parse_inference`.
  - `_whisper` sends `response_format=verbose_json` and returns `parse_inference(json.loads(...))`.
  - `transcribe` returns the tuple.
  - `_worker` stores `(text, ok, conf)`, cleaning only the text. `_commit` passes `conf` through to `add_commit`.
  - `Draft.create` gains keyword params `app=""` and `tier="personal"` and sets `origin` and `prompt_sha`.
  - `cmd_record`: call `focused_app()` once, before `Draft.create` (the recorder already started at import, line 182, so the lookup costs no audio), and compute `tier_for(app, CFG.get("work_apps", []), args.tier)`.
  - `cmd_file` passes `app=""`, which gives `tier` = `personal`.
  - `Session.push` adds `"tier"` from `draft.meta`.
- [ ] **Step 4: Run the tests and see them pass.** Same command. Expected: `OK`.
- [ ] **Step 5: Add the flake check** `perSystem.checks.dictation-capture` in `dictation.nix`. It's a `runCommand` with `python3.withPackages (ps: [ps.numpy ps.onnxruntime])` that copies `./dictation` and runs the same `unittest discover`. Run `nix build --no-link .#checks.x86_64-linux.dictation-capture`. Expected: it builds.
- [ ] **Step 6: Commit** `dictate: drafts record app, tier, origin, prompt hash; verbose_json confidences per segment`.

### Task 3: Desktop override and overlay (`dictate tier`, overlay label)

**Files:**
- Modify: `modules/nixos/features/dictation/dictate.sh` (`start()` ~line 116, the `case "$cmd"` dispatch ~line 249, `menu`, usage line ~322)
- Modify: `modules/nixos/features/dictation/dictate-overlay.py:161`

**Interfaces:**
- Consumes: `dictate-stream record --tier` and the overlay `tier` key (Task 2).
- Produces:
  - `dictate tier work|personal|auto`: writes or clears the one-shot file `tier` in `$state_dir` (the runtime dir `dictate.sh` already uses for `lang`/`mode`), then notifies "Next dictation: work" (or personal, or "tier from the app").
  - `start()` reads that file, passes `--tier <value>` when it is set, and deletes the file in the same step, so a cancelled or empty session doesn't leak the override.
  - `dictate menu` gains two entries: "Next dictation: work" and "Next dictation: personal".

- [ ] **Step 1: Implement the subcommand, the `start()` change, the menu entries and the usage line.**
- [ ] **Step 2: Overlay.** The meta label reads `f"{lang} · {tier} · {backend}"` when `tier` is present, as before when it isn't. Keep the colours on the existing palette classes; add no new colour.
- [ ] **Step 3: Verify.** `nix build --no-link .#nixosConfigurations.butternut.config.system.build.toplevel` (shellcheck runs in the wrapper build if it is a `writeShellApplication`; otherwise run `nix shell --inputs-from . nixpkgs#shellcheck -c shellcheck -x modules/nixos/features/dictation/dictate.sh`). Expected: no errors. Manual check after the user switches: `dictate tier work`, dictate into a non-work window, and confirm the newest `drafts/*/meta.json` has `"tier": "work"`. Then a second session in the same window gives `"personal"`.
- [ ] **Step 4: Commit** `dictate: one-shot tier override (dictate tier, menu); overlay shows the tier`.

### Task 4: Tier and app in phone drafts (`DraftStore`)

**Files:**
- Modify: `apps/phone/app/src/main/java/nixconf/phone/drafts/DraftStore.kt`
- Test: `apps/phone/app/src/test/java/nixconf/phone/drafts/DraftStoreTest.kt`

**Interfaces:**
- Produces:
  - `const val TIER_WORK = "work"`, `const val TIER_PERSONAL = "personal"` (in `DraftStore.kt`).
  - `Draft` gains `app: String?`, `tier: String` (default `TIER_PERSONAL`), `promptSha: String?`. `Meta` gains the same with defaults (`tier = TIER_PERSONAL`), plus `origin: String = "phone"`.
  - `DraftStore.create(language: String, app: String? = null, tier: String = TIER_PERSONAL, promptSha: String? = null): Draft`.
  - `@Serializable data class SegmentConf(val avgLogprob: Double, val noSpeechProb: Double, val words: List<WordConf> = emptyList(), val lang: String? = null, val langP: Double? = null)`, `@Serializable data class WordConf(val w: String, val p: Double, val start: Double, val end: Double)`.
  - `SegmentText` gains `conf: SegmentConf? = null`. Keep JSON names camelCase, as the existing phone files do; plan 2's inbox maps them.

- [ ] **Step 1: Write the failing tests** in `DraftStoreTest`:
  - `create_records_app_tier_and_prompt_hash`: `create("en", "com.example.chat", TIER_WORK, "abc123def456")`, then `load(id)` has those three values and `meta.json` contains `"origin":"phone"`.
  - `meta_without_tier_loads_as_personal`: write a meta.json in the old shape by hand (status, createdMs, updatedMs, language), then `load(id)!!.tier == TIER_PERSONAL` and `app == null`.
  - `segment_confidence_round_trips`: `addSegment` with a `SegmentConf` (two `WordConf`) and `segments(draft).single().conf` equals it. A segment without `conf` reads back `conf == null`.
- [ ] **Step 2: Run** `nix run .#phone-app -- test`. Expected: FAIL (unresolved `TIER_WORK`).
- [ ] **Step 3: Implement.** `update()` and `load()` carry the new fields through `Meta`. `lostMeta` drafts get the defaults.
- [ ] **Step 4: Run** `nix run .#phone-app -- test`. Expected: all pass, including the existing DraftStore tests.
- [ ] **Step 5: Commit** `Pollen: drafts record app, tier, prompt hash; segments keep Whisper confidence`.

### Task 5: `verbose_json` on the phone (`WhisperClient`, session wiring)

**Files:**
- Modify: `apps/phone/app/src/main/java/nixconf/phone/engine/WhisperClient.kt`
- Modify: `apps/phone/app/src/main/java/nixconf/phone/session/DictationSession.kt` (`transcribe` ~line 497, `Outcome`, `addSegment` call ~line 453, `start` ~line 187)
- Test: `apps/phone/app/src/test/java/nixconf/phone/engine/WhisperClientTest.kt`, `apps/phone/app/src/test/java/nixconf/phone/session/DictationSessionTest.kt` (fake at ~line 110)

**Interfaces:**
- Consumes: `SegmentConf`, `WordConf`, `DraftStore.create(language, app, tier, promptSha)` (Task 4).
- Produces:
  - `data class Transcript(val text: String, val conf: SegmentConf? = null)` in `WhisperClient.kt`.
  - `RemoteTranscriber.transcribe(url, wav, language, prompt): Transcript` (was `String`).
  - `fun parseInference(body: String): Transcript?`: same mapping as the desktop `parse_inference`. Null when there's no `text`.
  - `EditorTarget` gains `val app: String? get() = null` and `val tier: String get() = TIER_PERSONAL`. `DictationSession.start(language, target)` passes `target.app`, `target.tier` and `promptSha(p?.prompt.orEmpty())` to `drafts.create`.
  - `fun promptSha(prompt: String): String`: 12 hex of SHA-256, in `WhisperClient.kt`.

- [ ] **Step 1: Write the failing tests.**
  - `WhisperClientTest.transcribe_sends_verbose_json_and_reads_confidence`: MockWebServer answers a verbose fixture (invented words). Assert that the recorded request body contains `verbose_json`, that `result.text` matches, that `result.conf!!.avgLogprob` is the minimum and `noSpeechProb` the maximum, and that `words.size` is right.
  - `transcribe_plain_json_has_no_conf`: body `{"text":"hi"}` gives `Transcript("hi", null)`.
  - Keep the existing no-`text` test throwing `IOException`.
  - `DictationSessionTest`: the fake returns `Transcript(text)`. Add `segment_confidence_is_stored`: the fake returns a `conf`, and `drafts.segments(draft).first().conf` equals it. Add `draft_records_target_tier`: a target with `app = "com.example.chat"` and `tier = TIER_WORK` makes the created draft carry both.
- [ ] **Step 2: Run** `nix run .#phone-app -- test`. Expected: FAIL (compile: `Transcript` unresolved).
- [ ] **Step 3: Implement.**
  - `transcribe` sends `verbose_json` and parses it with `parseInference`.
  - `Outcome` carries `conf`, and `addSegment` stores it.
  - The local (Parakeet) path stores `conf = null`.
- [ ] **Step 4: Run** `nix run .#phone-app -- test`. Expected: all pass.
- [ ] **Step 5: Commit** `Pollen: Whisper verbose_json; segment confidence and target tier reach the draft`.

### Task 6: The tier chip (Pollen panel, profile `workApps`)

**Files:**
- Create: `apps/phone/app/src/main/java/nixconf/phone/ime/Tier.kt`
- Modify: `apps/phone/app/src/main/java/nixconf/phone/profile/Profile.kt` (field `workApps`)
- Modify: `apps/phone/app/src/main/java/nixconf/phone/ime/DictationIme.kt` (`onStartInput` ~line 146, `PanelModel`/`PanelActions` construction ~line 100)
- Modify: `apps/phone/app/src/main/java/nixconf/phone/ime/Panel.kt` (top row ~line 125; `PanelModel`, `PanelActions`)
- Modify: `apps/phone/app/src/main/java/nixconf/phone/ime/PanelText.kt` (chip label and announcement)
- Modify: `modules/nixos/features/dictation-server.nix` (`phone.workApps` option; `base` profile attrs ~line 237)
- Test: `apps/phone/app/src/test/java/nixconf/phone/ime/TierTest.kt` (create), `PanelTextTest.kt`, `ProfileTest.kt`

**Interfaces:**
- Consumes: `TIER_WORK`, `TIER_PERSONAL` (Task 4); `EditorTarget.app`/`tier` (Task 5).
- Produces:
  - `fun tierFor(pkg: String?, workApps: List<String>, override: String?): String`, with the same rules as the desktop `tier_for` (exact package match).
  - `Profile.workApps: List<String> = emptyList()`.
  - Nix `preferences.dictation-server.phone.workApps` (`listOf str`, default `[]`, description: "Android packages whose dictation is work tier; everything else is personal"), passed into the profile JSON.
  - `PanelModel` gains `tier: String?` (null in incognito/password fields: no chip). `PanelActions` gains `flipTier: () -> Unit`.
  - `fun tierLabel(tier: String): String` ("Work" / "Personal") and `fun tierAnnouncement(tier: String): String` ("Tier: Work. Double-tap to make this draft Personal", and vice versa) in `PanelText.kt`.

- [ ] **Step 1: Write the failing tests.**
  - `TierTest`: the same seven cases as the desktop `test_tier_for`, with package names (`"com.example.chat"` etc.).
  - `PanelTextTest`: `tierLabel(TIER_WORK) == "Work"`; the announcement strings as above.
  - `ProfileTest`: a profile JSON without `workApps` parses to `emptyList()`, and one with `["a.b"]` parses to it.
- [ ] **Step 2: Run** `nix run .#phone-app -- test`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `DictationIme`: keep `pkg` from `onStartInput`. Keep `tierOverride: String?`, reset to null when `onStartInput` sees a different package (not on `restarting` within the same package). `tier` = `tierFor(pkg, profile.workApps, tierOverride)`; `app` = `pkg`. `flipTier` sets the override to the opposite of the current tier. Clear the override once a recording has started with it (one draft only).
  - Panel: the chip goes in the top row right after the language button, as a `TextButton`-height pill. Work: a 2 dp border in `colorScheme.primary` ("one ink" maps to Material's primary on the phone). Personal: an `outlineVariant` border plus a small lock icon (`Icons.Outlined.Lock`, or a vector if material-icons isn't a dependency; check `build.gradle.kts` and don't add a dependency only for this). Disabled while recording. Not shown when `tier == null`. Semantics: `tierAnnouncement`.
  - Nix: add `phone.workApps` and pass it in the `base` attrset next to `mode`.
- [ ] **Step 4: Run** `nix run .#phone-app -- test`, then `nix build --no-link .#checks.x86_64-linux.phone-profile`. Expected: both pass. The profile check walks `Profile.kt` against the served JSON, so the new field must be in both.
- [ ] **Step 5: Look at it.** `nix run .#phone-app -- build`. Then the user installs and screenshots the panel in a work app and a chat app (device tools if the phone is connected; otherwise ask the user). The chip must not push the "N drafts" button off the row at 360 dp width. If it does, shorten the labels to "Work" and a lock icon only.
- [ ] **Step 6: Commit** `Pollen: tier chip in the panel (work list from the profile, one-draft flip)`.

### Task 7: Finish

- [ ] **Step 1: Work lists with the user.** The phone `workApps` default is `[]`. Ask the user which installed apps are work. They can run `adb shell pm list packages -3 | sort`, or name them. Set them on butternut: `preferences.dictation-server.phone.workApps` in `hosts/butternut/configuration.nix`. Only package names go in git, which are not personal.
- [ ] **Step 2: Repo checks.** `just check` (or the raw commands in `justfile`) and `nix run .#phone-app -- test`. Expected: all pass. `eval-all` OK for every host except the known-skipped `niri-desktop-vm`.
- [ ] **Step 3: Rebase and PR.** `git rebase main`, then `nix run .#fleet -- affects`, `agent-push`, and `gh pr create` with the `Affects:` line in the body. Link the PR.
- [ ] **Step 4: User follow-up (they run these).** Deploy butternut and hazel (`just deploy butternut`, `just deploy hazel`), then `nix run .#phone-app -- publish` and update Pollen from its app screen.
