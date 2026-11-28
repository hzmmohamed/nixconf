# Dictation training lab, plan 2 of 6: Hub

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every delivered dictation draft, from the phone, hazel and butternut, arrives in one normalized tree on butternut and stays there past the 7-day window. Personal text never leaves your own machines.

**Architecture:** A small Python stdlib HTTP server, `dictate-lab serve`, runs as the user on butternut, port 8181. It accepts draft files with `PUT`, normalizes them on `POST …/done`, and lets in only loopback and your own untagged tailnet devices (`tailscale whois`). `dictate-stream push` uploads laptop drafts after each session and hourly. Pollen uploads delivered drafts on unmetered networks. Neither side prunes a draft before it is uploaded. A daily `dictate-lab prune` drops full audio after 90 days, except Arabic.

**Tech Stack:** Python 3 stdlib (`http.server`, `urllib`, `unittest`), opus-tools, Nix (new `dictation-lab` feature, `dictation`, `dictation-server`), Kotlin (OkHttp, JUnit + MockWebServer).

**Spec:** `docs/plans/2026-11-25-dictation-training-lab-design.md` (§5.1, §5.2, §5.6, §5.7, §6 phase 2). Plan 1 (merged, #11) defined the capture fields.

**Decisions made while planning (not in the spec):**
- The phone uploads only on unmetered networks, the same rule as the model download (`AppServices.isUnmetered`).
- Only delivered drafts are uploaded. Pending ones wait until delivered; cancelled and incognito drafts never leave the device.
- Files go up as separate `PUT`s, then `POST done`. That avoids multipart parsing (`cgi` is gone from Python 3.13).
- Both sides keep an unsent delivered draft up to `unsentDays` = 30 days instead of `keepDays`.
- The server normalizes on arrival, so plans 3–6 read one schema.
- The peer rule: loopback; or a tailnet peer whose `UserProfile.ID` equals butternut's own user and whose node has no tags (fern, `tag:agent-host`, is refused).

## Global Constraints

- **Normalized lab tree:** `<dataDir>/drafts/<origin>/<id>/`, holding:
  - `meta.json`, fields `id, origin, created_ms, lang, tier, app, prompt_sha, engine, text, duration, received_ms, source`;
  - `segments.jsonl`, fields per line `i, start, end, text, ok, conf?`, with `start`/`end` in samples at 16 kHz and `conf` keys `avg_logprob, no_speech_prob, words[{w,p,start,end}], lang, lang_p`;
  - `audio.opus`;
  - `source/`, the files exactly as uploaded except the audio.
- `tier` in the normalized meta is `"work"` only if the source said exactly `"work"`; otherwise `"personal"`.
- `origin` is `^[a-z0-9-]{1,32}$` and `id` is `^[A-Za-z0-9._-]{1,64}$`, never `.` or `..`. Anything else gets 400.
- Uploads are idempotent: the same id replaces the draft. `POST done` with no audio file is 400.
- Body limit: 256 MiB per `PUT`, `Content-Length` required. Otherwise 411/413.
- Never log transcript text. Log id, origin, sizes and status only.
- Port 8181. Not added to `preferences.trustedNetworks` (tailnet only). No new key bindings.
- Public repo: invented text in every fixture. No hostnames hardcoded in features; host configs may name hosts.
- New files: `git add -N`. Before handing back: run the new `tests/` dirs, `just check`, `nix run .#phone-app -- test`.

## Review Focus

- **butternut is off or unreachable** when the phone or hazel finishes a draft: nothing is lost. The draft stays (even past `keepDays`, up to `unsentDays`) and goes up at the next chance, without blocking the keyboard or the next dictation.
- **An upload interrupted halfway** (some `PUT`s done, no `done`): the server keeps nothing half-normalized. The next full upload replaces it cleanly.
- **The same draft uploaded twice**, for example after a crash before the client recorded `uploaded`, ends up as one draft, not two.
- **A request from a LAN address, another user's node or a tagged node** is refused before any file is written. If `tailscale whois` is missing or errors, the request is refused (fail closed).
- **An old laptop draft without `tier`**, or a phone draft from before plan 1, uploads and normalizes to `personal`.

---

### Task 1: The inbox server (`dictate-lab serve`)

**Files:**
- Create: `modules/nixos/features/dictation-lab/dictate-lab.py`
- Create: `modules/nixos/features/dictation-lab/tests/test_inbox.py`

**Interfaces:**
- Produces (module-level in `dictate-lab.py`):
  - `normalize(origin: str, src: dict[str, bytes]) -> tuple[dict, list[dict]]`: the normalized `meta` and `segments` from the uploaded files. Keys of `src` are file names: `meta.json`, plus `segments.jsonl` (phone) or `commits.jsonl` (laptop).
  - Phone mapping:
    - `createdMs → created_ms`, `language → lang`, `engine → engine`, `text → text`;
    - `tier`, `app`, `promptSha → prompt_sha`;
    - segment `conf` camelCase keys → snake_case (`avgLogprob → avg_logprob`, `noSpeechProb → no_speech_prob`, `langP → lang_p`).
  - Laptop mapping:
    - `t0` (seconds) × 1000 → `created_ms`;
    - `lang`, `backend → engine`, `tier`, `app`, `prompt_sha`, `duration`;
    - `text` = the commits' texts joined with single spaces (ok ones only);
    - segments from `commits.jsonl` (`i, start, end, text, ok, conf`).
  - `to_opus(name: str, data: bytes, dest: Path) -> None`: converts `audio.wav` and `audio.pcm` (s16le, 16 kHz, mono) with `opusenc --bitrate 24 --speech`, and copies `audio.opus` as is. Raises `ValueError` on any other name.
  - `class PeerCheck(whois: Callable[[str], dict | None], self_user: int, allow_loopback: bool = True)`, with `allowed(ip: str) -> bool`. True for `127.0.0.1`/`::1` when `allow_loopback`, or when `whois(ip)` has `UserProfile.ID == self_user` and `Node.Tags` is empty. A `None` or failed `whois` gives False. Results are cached per IP for 300 s.
  - `make_server(data_dir: Path, port: int, peers: PeerCheck) -> ThreadingHTTPServer`, with these routes:
    - `GET /health` → 200 `{"ok": true}`;
    - `PUT /inbox/<origin>/<id>/<file>`, `file` ∈ {`meta.json`, `segments.jsonl`, `commits.jsonl`, `audio.wav`, `audio.pcm`, `audio.opus`} → 204, written to `<data_dir>/incoming/<origin>/<id>/<file>`;
    - `POST /inbox/<origin>/<id>/done` → normalize into `<data_dir>/drafts/<origin>/<id>.tmp/`, then atomically replace `<data_dir>/drafts/<origin>/<id>/` and delete the incoming dir → 200 `{"ok": true, "id": …}`;
    - 403 for a peer that fails the check, checked before reading the body;
    - 400 for bad names and 404 for anything else.
  - CLI: `dictate-lab serve --data-dir D --port P`. `whois` shells out to `tailscale whois --json <ip>`, and `self_user` comes from `tailscale status --json` (`.Self.UserID`).

- [ ] **Step 1: Write the failing tests** in `tests/test_inbox.py`. Load the script with importlib (hyphenated name). Start `make_server` on port 0 in a thread, with a temp `data_dir` and `PeerCheck(fake_whois, self_user=7)`, and send requests with `http.client`. Tests:
  - `test_phone_draft_normalizes`:
    - PUT a phone `meta.json` (`{"status":"delivered","createdMs":1700000000000,"updatedMs":1,"language":"en","engine":"http://x:8178","text":"an invented line","tier":"work","app":"com.example.agent","promptSha":"abc123def456","origin":"phone"}`), a `segments.jsonl` with one line carrying `conf` in camelCase, and a 0.5 s silent WAV, then `done`.
    - Assert `drafts/phone/<id>/meta.json` has `tier == "work"`, `lang == "en"`, `created_ms == 1700000000000`, `prompt_sha == "abc123def456"`, `origin == "phone"`.
    - Assert `segments.jsonl` line 0 has `conf["avg_logprob"]`.
    - Assert `audio.opus` exists, and `incoming/phone/<id>` is gone.
  - `test_laptop_draft_normalizes`: a laptop `meta.json` (`t0`, `lang`, `backend`, `tier: "personal"`, `prompt_sha`, `duration`), `commits.jsonl` with two ok lines and one `ok: false`, and `audio.pcm` (8000 zero samples). The resulting `text` is the two ok texts joined, `engine` is the backend, `created_ms == t0*1000`, and `segments.jsonl` has 3 lines.
  - `test_missing_or_odd_tier_is_personal`: a meta with no `tier`, and one with `tier: "Work"`, both normalize to `"personal"`.
  - `test_reupload_replaces`: the same id uploaded twice with different text leaves one draft with the second text.
  - `test_partial_upload_leaves_no_draft`: `PUT meta.json` only, no `done` → `drafts/` has no such id.
  - `test_done_without_audio_is_400`.
  - `test_bad_names_rejected`: origin `"../x"`, id `".."`, file `"evil.sh"` → 400, and nothing is written outside `data_dir`.
  - `test_foreign_peer_refused`: when `fake_whois` returns `{"UserProfile":{"ID":8},"Node":{"Tags":[]}}` for the test client's IP, the `PUT` gets 403 and nothing is written. Same for `ID: 7` with `Tags: ["tag:agent-host"]`, and for `whois` returning None.
    - The server under test is built with `allow_loopback=False`, and `fake_whois` is keyed on `"127.0.0.1"`.
  - `test_body_limits`: `PUT` without `Content-Length` → 411.
- [ ] **Step 2: Run** `python3 -m unittest discover -s modules/nixos/features/dictation-lab/tests -v`, with `opusenc` on PATH (`nix shell --inputs-from . nixpkgs#opus-tools -c …`). Expected: FAIL (the script doesn't exist).
- [ ] **Step 3: Implement** `dictate-lab.py` to the interfaces above. Write files via a `.part` file and rename. In `POST done`, normalize into `<id>.tmp`, then `os.replace`; if the target exists, rename it aside first and delete it after. Use `ThreadingHTTPServer` and log one line per draft to stderr: origin, id, bytes, status.
- [ ] **Step 4: Run** the same command. Expected: `OK`.
- [ ] **Step 5: Commit** `dictation lab: inbox server (normalize phone and laptop drafts; own devices only)`.

### Task 2: The `dictation-lab` feature and retention

**Files:**
- Modify: `modules/nixos/features/dictation-lab/dictate-lab.py` (add `prune`)
- Modify: `modules/nixos/features/dictation-lab/tests/test_inbox.py` (or create `test_prune.py`)
- Create: `modules/nixos/features/dictation-lab.nix`
- Modify: `modules/nixos/hosts/butternut/configuration.nix` (import, phone lab URL)

**Interfaces:**
- Consumes: Task 1's CLI.
- Produces:
  - `prune(data_dir: Path, audio_days: int, keep_lang: list[str], now_ms: int) -> int`: deletes `audio.opus` from drafts whose `received_ms` is older than `audio_days`, unless `meta.lang` is in `keep_lang`. Text and segments are kept. Returns the number of audio files deleted. CLI: `dictate-lab prune --data-dir D --audio-days N --keep-lang ar`.
  - Nix `flake.nixosModules.dictation-lab`, with options under `preferences.dictation-lab`:
    - `port` (8181);
    - `dataDir` (str, default `".local/state/dictation/lab"`, relative to home);
    - `audioDays` (90);
    - `keepAudioLanguages` (`["ar"]`);
    - `url` (readOnly, `http://<hostName>.<self.tailnet.domain>:<port>`).
  - Home-manager user units:
    - `dictation-lab.service`: `serve`, `Restart=on-failure`, `WantedBy=default.target`; butternut lingers. Its PATH has `tailscale` and `opus-tools`.
    - `dictation-lab-prune.service` plus a daily timer.
  - The feature adds `persistance.data.directories = [cfg.dataDir]`, like the dictation feature. Check it's a no-op on butternut if it doesn't use impermanence.
  - A flake check `checks.dictation-lab` that runs `tests/` with python3 and opus-tools, the same pattern as `checks.dictation-capture`.

- [ ] **Step 1: Write the failing test** `test_prune_drops_old_audio_keeps_arabic_and_text`, with three drafts written straight into the tree:
  - old English: `audio.opus` deleted, `meta.json` kept;
  - old Arabic: kept;
  - new English: kept.
  Returns 1.
- [ ] **Step 2: Run** the tests. Expected: FAIL (`prune` not defined).
- [ ] **Step 3: Implement `prune` and the Nix feature.** Import it in `hosts/butternut/configuration.nix`. Add `git add -N` for the new files.
- [ ] **Step 4: Verify.**
  - The tests: `OK`.
  - `nix build --no-link .#checks.x86_64-linux.dictation-lab` builds.
  - `nix eval --raw .#nixosConfigurations.butternut.config.preferences.dictation-lab.url` prints `http://butternut.<domain>:8181`.
  - `just eval butternut` prints a drv.
  - Smoke-run the real server once from the worktree against a temp dir: `python3 …/dictate-lab.py serve --data-dir $tmp --port 18181 &`, `curl -s 127.0.0.1:18181/health` gives `{"ok": true}`, then kill it.
- [ ] **Step 5: Commit** `dictation lab: dictation-lab feature on butternut (user service, daily audio retention)`.

### Task 3: Laptop uploads (`dictate-stream push`)

**Files:**
- Modify: `modules/nixos/features/dictation/dictate-stream.py`
- Modify: `modules/nixos/features/dictation.nix` (option `labUrl`, `lab_url` and `unsent_days` in `streamConfig`, push timer)
- Modify: `modules/nixos/hosts/hazel/configuration.nix`, `modules/nixos/hosts/butternut/configuration.nix` (set `labUrl`)
- Create: `modules/nixos/features/dictation/tests/test_push.py`

**Interfaces:**
- Consumes: Task 1's routes.
- Produces:
  - `push(d: Draft, url: str, timeout: float = 10) -> bool`:
    - Pushes only `status == "done"` drafts not already uploaded, where `meta.get("uploaded")` is falsy.
    - Sends `PUT meta.json`, `commits.jsonl` and whichever of `audio.opus` / `audio.pcm` exists, then `POST done`.
    - On 2xx: `d.save(uploaded=int(time.time()))` and return True. Any error returns False and logs `push <id>: <reason>`, without text.
  - `cmd_push`: `dictate-stream push [--all | ID]`. Uses `CFG.get("lab_url")`; when unset, prints "no lab configured" and exits 0.
  - `cmd_record`: after `draft.compress()`, call `push(draft, CFG["lab_url"])` when `lab_url` is set (in the process, after the session has gone idle, so it doesn't delay typing).
  - `prune()` gains a rule: when `CFG.get("lab_url")` is set, a `done` draft without `uploaded` is kept until `unsent_days` (default 30) instead of `keep_days`.
  - Nix:
    - `preferences.dictation.labUrl`: `nullOr str`, default null. Description: "Dictation training lab inbox (dictation-lab feature); delivered drafts are uploaded there. null: no uploads."
    - `preferences.dictation.unsentDays` (30).
    - A user timer `dictate-drafts-push`, hourly, `Persistent=true`, running `dictate-stream push --all`. Only when `labUrl != null`.
  - Hosts:
    - butternut: `labUrl = "http://127.0.0.1:8181"`;
    - hazel: `labUrl = "http://butternut.${self.tailnet.domain}:8181"`. Check that `self` is in scope in hazel's config; hazel's dictation servers list already names butternut.

- [ ] **Step 1: Write the failing tests** in `tests/test_push.py`. Load dictate-stream as `test_capture.py` does, set `lab_url` in the temp config, and start a recording fake server (stdlib `http.server`) that stores each request's method, path and body length.
  - `test_push_sends_files_then_done_and_marks_uploaded`: a `done` draft with `commits.jsonl` and `audio.pcm` produces requests in order `PUT …/meta.json`, `PUT …/commits.jsonl`, `PUT …/audio.pcm`, `POST …/done`. The path has the origin from `socket.gethostname()`. The draft's meta then has `uploaded`.
  - `test_push_skips_pending_and_uploaded`: no requests for either.
  - `test_push_failure_keeps_draft_unsent`: when the server answers 500 on `done`, `push` returns False and `uploaded` is absent.
  - `test_prune_keeps_unsent_until_unsent_days`: with `keep_days` 7 and `unsent_days` 30, a `done` draft 10 days old without `uploaded` is kept; with `uploaded` it is pruned; one 31 days old is pruned either way.
- [ ] **Step 2: Run** `python3 -m unittest discover -s modules/nixos/features/dictation/tests -v` (with numpy and onnxruntime, as in plan 1). Expected: the new tests FAIL.
- [ ] **Step 3: Implement** with `urllib.request` (the method set per request).
- [ ] **Step 4: Run.** Expected: all pass, including plan 1's tests. Then `nix build --no-link .#checks.x86_64-linux.dictation-capture`, `just eval hazel` and `just eval butternut`.
- [ ] **Step 5: End-to-end on butternut.**
  - Start the real server (Task 2's smoke command) on 18181 against a temp dir.
  - Copy one real draft dir from `~/.local/state/dictation/drafts/` into a temp `journal_dir` (local only: it never leaves the machine).
  - Run `dictate-stream push --all` with a config whose `lab_url` is `http://127.0.0.1:18181`.
  - Check that the normalized `meta.json` has the right `tier`/`lang`, and that `audio.opus` plays (`opusinfo`).
  - Delete the temp dirs with `find <tmp> -delete` (`rm -r` is denied).
- [ ] **Step 6: Commit** `dictate: upload delivered drafts to the lab (after each session, hourly); keep unsent ones`.

### Task 4: Phone drafts remember the upload

**Files:**
- Modify: `apps/phone/app/src/main/java/nixconf/phone/drafts/DraftStore.kt`
- Test: `apps/phone/app/src/test/java/nixconf/phone/drafts/DraftStoreTest.kt`

**Interfaces:**
- Produces:
  - `Draft.uploadedMs: Long? = null` and `Meta.uploadedMs: Long? = null`.
  - `DraftStore.toUpload(): List<Draft>`: DELIVERED drafts with `uploadedMs == null`, oldest first.
  - `DraftStore.prune(keepDays: Int, unsentDays: Int? = null)`: when `unsentDays` is non-null, a DELIVERED draft without `uploadedMs` is kept until `unsentDays` instead of `keepDays`. CANCELLED drafts are unchanged.
  - `DraftStore.files(draft): List<File>`: `meta.json`, `segments.jsonl` if present, `audio.wav`.

- [ ] **Step 1: Write the failing tests:**
  - `to_upload_lists_delivered_not_uploaded`: a pending, a cancelled, a delivered and a delivered-and-uploaded draft → only the third.
  - `prune_keeps_unsent_delivered_until_unsent_days`: at 10 days, with keep 7 and unsent 30, it is kept; at 31 days it is pruned; uploaded at 10 days is pruned; `unsentDays = null` keeps today's behaviour.
  - `uploaded_round_trips`.
- [ ] **Step 2: Run** `nix run .#phone-app -- test`. Expected: FAIL (compile).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: all pass.
- [ ] **Step 5: Commit** `Pollen: drafts remember the lab upload; unsent ones outlive keepDays`.

### Task 5: Pollen uploads (`LabUploader`, profile `lab`)

**Files:**
- Create: `apps/phone/app/src/main/java/nixconf/phone/lab/LabUploader.kt`
- Create: `apps/phone/app/src/test/java/nixconf/phone/lab/LabUploaderTest.kt`
- Modify: `apps/phone/app/src/main/java/nixconf/phone/profile/Profile.kt` (`lab: String? = null`, `unsentDays: Int = 30`)
- Modify: `apps/phone/app/src/main/java/nixconf/phone/AppServices.kt` (wiring, triggers, prune call)
- Modify: `apps/phone/app/src/main/java/nixconf/phone/ui/MainActivity.kt` (one line)
- Modify: `modules/nixos/features/dictation-server.nix` (`phone.lab`, `phone.unsentDays`), `modules/nixos/hosts/butternut/configuration.nix`
- Test: `ProfileTest.kt`

**Interfaces:**
- Consumes: `DraftStore.toUpload/files/update` (Task 4); routes (Task 1).
- Produces:
  - `class LabUploader(http: OkHttpClient, drafts: DraftStore, clock: () -> Long)`, with `suspend fun uploadAll(lab: String): Int`.
    - For each `toUpload()` draft, in order: `PUT <lab>/inbox/phone/<id>/<file>` for each of `files(draft)`, then `POST …/done`. On 2xx, `drafts.update(draft.copy(uploadedMs = clock()))`.
    - It stops at the first failure: the server is unreachable, so the rest wait.
    - Returns the number uploaded. Runs on `Dispatchers.IO`.
  - `Profile.lab: String? = null`, `Profile.unsentDays: Int = 30`.
  - `AppServices`:
    - `val unsent: StateFlow<Int>` (count of `toUpload()`).
    - `uploadIfUnmetered()`, called at the end of `onOpen` and when the session reaches `Done`. It runs only when `profile.lab != null && isUnmetered()`, and never runs two uploads at once.
    - `onOpen`'s prune passes `p?.unsentDays` when `p?.lab != null`.
  - MainActivity: a line "N drafts waiting to send to the lab", shown only when `unsent > 0`. Use the existing list item style: a plain `Text` in the list, no card.
  - Nix: `preferences.dictation-server.phone.lab` (`nullOr str`, default null, description "Dictation training lab inbox URL the phone uploads delivered drafts to (MagicDNS FQDN)") and `phone.unsentDays` (30). Both go into the profile JSON. butternut sets `phone.lab = config.preferences.dictation-lab.url`.

- [ ] **Step 1: Write the failing tests:**
  - `LabUploaderTest.uploads_files_then_done_and_marks`: MockWebServer gets 3 PUTs and 1 POST with the right paths and bodies, and the draft gets `uploadedMs`.
  - `stops_at_first_failure`: with two drafts and a 500 on the first `done`, there are no requests for the second, and neither is marked.
  - `nothing_to_upload_makes_no_requests`.
  - `ProfileTest.lab_fields_default`: `lab` is null and `unsentDays` is 30 when absent; parses when present.
- [ ] **Step 2: Run** `nix run .#phone-app -- test`. Expected: FAIL.
- [ ] **Step 3: Implement.** Then the Nix options, the butternut setting, and `nix build --no-link .#checks.x86_64-linux.phone-profile`: the profile check needs the new fields in both places.
- [ ] **Step 4: Run** the phone tests and the profile check. Expected: pass. Then `nix run .#phone-app -- build`.
- [ ] **Step 5: Commit** `Pollen: upload delivered drafts to the lab on unmetered networks`.

### Task 6: Finish

- [ ] **Step 1:** Run `python3 -m unittest` for both `tests/` dirs, `just check`, and `nix run .#phone-app -- test`. Expected: all pass.
- [ ] **Step 2:** `nix run .#fleet -- affects`, `agent-push`, and `gh pr create` with the `Affects:` line in the body. Link the PR.
- [ ] **Step 3: User follow-up** (they run these):
  - `just deploy butternut` and `just deploy hazel`;
  - `nix run .#phone-app -- publish`, then update Pollen;
  - check on butternut: `systemctl --user status dictation-lab`, and after a dictation, `ls ~/.local/state/dictation/lab/drafts/*/`.
