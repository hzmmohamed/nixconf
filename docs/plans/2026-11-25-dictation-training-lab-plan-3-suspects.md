# Dictation training lab, plan 3 of 6: Suspects

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The lab finds likely transcription mistakes in every draft without any model. It uses cheap rules on Whisper's confidences and text, plus the edits you made to dictated agent prompts before sending them. A command-line census shows how often each kind happens, per week.

**Architecture:** Three new `dictate-lab` subcommands and two API routes on the plan 2 server:
- `dictate-lab analyse` runs hourly on butternut over the lab tree and appends heuristic suspects to `suspects.jsonl`.
- `dictate-lab mine` runs hourly on every host with a `labUrl` (butternut, hazel). It fetches recent drafts from `GET /api/drafts` and matches them to your sent messages in `~/.claude/projects/*/*.jsonl`. The word-level differences go back to `POST /api/mined` as suspects whose suggestion is your edit.
- `dictate-lab census` prints counts. Everything stays on your machines; no model is called in this plan.

**Tech Stack:** Python 3 stdlib (`difflib`, `fcntl`, `http.server`, `urllib`, `unittest`), hunspell with the en_US dictionary (nixpkgs), Nix (`dictation-lab`, `dictation`).

**Spec:** `docs/plans/2026-11-25-dictation-training-lab-design.md` (§2, §3, §5.3 sources 1–2, §6 phase 3). Plan 2 (#12) defined the lab tree and the server.

**Decisions made while planning (not in the spec):**
- **No Arabic dictionary:** nixpkgs has no Arabic hunspell dictionary, so the out-of-dictionary rule checks Latin-script words only. Arabic drafts get the other rules.
- **Packaging:** `dictate-lab` becomes a flake package, `packages.dictate-lab`. Both features use that one package, so butternut gets no duplicate in its user profile.
- **Span addressing:** a suspect points to `segment` (the segment's `i`, or `null` when a draft has no segments) and to character offsets `start`/`end` (half-open) in that segment's text, or in `meta.text` when `segment` is `null`. The game later plays the segment's audio.
- **Suspect ids:** the first 12 hex chars of `sha1("<draft>|<segment>|<start>|<end>|<source>")`. Re-running `analyse` or `mine` adds nothing new. Overlapping rules on one span keep the highest score.
- **What `mine` emits:** replacements and deletions of at most 4 words a side. Larger rewrites are changes of intent; insertions (words you added) are skipped. A change of case or punctuation only is `punct`, at score 0.3.
- **Matching:** a draft of at least 4 words matches a message sent in the window `[created_ms − 1 min, created_ms + duration + 30 min]`. Coverage, the fraction of the draft's normalized words found in the message, must be at least 0.6. The best match per draft wins, and a message may match several drafts.
- **Match records:** each match is kept in `matches.jsonl` (draft, app, tier). The census reports how many drafts were checked against agent prompts, and which apps' personal drafts turned up in agent sessions (the work-list hint; shown, never applied).
- **Census output:** counts by default. `--pairs` prints the repeated (from → to) edits. Those are transcript fragments, for the user's own terminal only.

## Global Constraints

- **Lab tree (plan 2):** `<dataDir>/drafts/<origin>/<id>/{meta.json, segments.jsonl, audio.opus}`.
  - meta has `id, origin, created_ms, lang, tier, app, text, duration, received_ms`.
  - Segments have `i, start, end, text, ok, conf?`, and `conf` holds `avg_logprob, no_speech_prob, words[{w,p,start,end}], lang, lang_p`.
  - Skip any dir ending in `.tmp` and any draft whose meta does not parse.
- **New files in `<dataDir>`:**
  - `suspects.jsonl`: one object per line, `{id, draft, segment, start, end, text, suggestion, kind, source, score, found_ms}`. `draft` is `"<origin>/<id>"`, `suggestion` is a string or `null`, and `text == segment_text[start:end]`.
  - `matches.jsonl`: one object per line, `{draft, app, tier, sent_ms, coverage}`.
  - `analysed.json`: `{"<origin>/<id>": received_ms}`.
- `kind` ∈ `term, punct, language, hallucination, grammar, other`. `source` is `heuristic` or `agent-diff`.
- **Writes:** both files are appended only under an exclusive `fcntl.flock` on `<dataDir>/suspects.lock`, because the server and `analyse` both write them.
- **No model calls in this plan.** The tier is copied into matches but not used to gate anything, since nothing leaves your machines.
- **Logging:** never log or print transcript text, except `census --pairs`. Logs carry ids, counts and sizes only.
- `GET /api/*` and `POST /api/*` go through the plan 2 `PeerCheck` (403 otherwise). `GET /health` stays open.
- **Public repo:** invented text in every fixture. No hostnames in features.
- **Before handing back:** `git add -N` for new files; run the `tests/` dirs of `dictation-lab` and `dictation`, then `just check`.

## Review Focus

- **Arabic, or mixed Arabic and English.** No crash and no out-of-dictionary suspects for Arabic-script words; the language rule still applies.
- **A draft with no confidences** (Parakeet, or a pre-plan-1 draft) gets only the text rules (vocabulary, dictionary, repeats, stock phrases), without errors.
- **Running `analyse` or `mine` twice in a row** adds no line the second time.
- **Short or generic messages** ("yes", "continue", a two-word draft) never match a draft, even when sent in the window.
- **Torn or odd input** is skipped, not fatal: a half-written session line, a user line whose content is a list of tool results, a `<command-name>` message, a sidechain (subagent) message, or a draft dir mid-swap (`.tmp`).

---

### Task 1: Heuristic rules

**Files:**
- Modify: `modules/nixos/features/dictation-lab/dictate-lab.py` (new section `# --- suspects`)
- Create: `modules/nixos/features/dictation-lab/tests/test_heuristics.py`

**Interfaces:**
- Produces:
  - `tokens(text: str) -> list[tuple[int, int, str]]`: `re.finditer(r"\S+")` spans.
  - `norm(token: str) -> str`: lowercased, with leading and trailing `.,;:!?"'()[]،؛؟` stripped.
  - `suspect_id(draft, segment, start, end, source) -> str`.
  - `make_suspect(draft, segment, seg_text, start, end, kind, source, score, suggestion=None, now_ms=None) -> dict`: fills `id`, `text`, `found_ms`.
  - `heuristic_suspects(meta: dict, segments: list[dict], vocab: list[str], oov: Callable[[list[str]], set[str]], now_ms: int) -> list[dict]`: one per span (highest score wins).
  - Constants: `LOW_P = 0.35`, `NO_SPEECH = 0.6`, `REPEAT = 3`, `STOCK = {"thank you.", "thanks for watching!", "thank you for watching.", "you"}`.
- Rules, in segment order, over `ok` segments with text:
  - **Low probability.** A `conf.words` entry with `p < LOW_P`, located in the segment text by a forward search from a cursor, gives score `1 − p`. Kind `term` if the token is capitalised and not the segment's first, has a digit or one of `-_./`, or is in `oov`; else `other`. If the word is not found, skip it.
  - **Near a vocabulary entry.** A token (or an n-gram the same length as a multi-word entry) whose `norm` is not equal to the entry's lowercase is within Levenshtein 1 (entries of 5 chars or fewer) or 2 (longer), with only 1 allowed for 3 chars or fewer. Kind `term`, score 0.8, suggestion = the entry.
  - **Out of dictionary.** Latin-script tokens of an `en` draft, by `norm`, minus vocabulary words (case-insensitive), minus tokens with digits. Those `oov()` returns are kind `term`, score 0.5.
  - **Text over silence.** `conf.no_speech_prob > NO_SPEECH` marks the whole segment: kind `hallucination`, score = that value.
  - **Stock phrase.** The stripped, lowercase segment text in `STOCK` marks the whole segment: `hallucination`, 0.7.
  - **Repeats.** An n-gram (n = 1..4) of `norm` tokens repeated `REPEAT`+ times in a row gives `hallucination`, 0.9, spanning the repeats.
  - **Wrong script.** An `en` draft segment holding Arabic letters (`[؀-ۿ]`), or an `ar` draft segment with none, marks the whole segment: `language`, 0.6.
- A draft with no segments runs the text rules over `meta.text` with `segment: null`.

- [ ] **Step 1: Write the failing tests** in `test_heuristics.py`. Load the script with importlib, as `test_inbox.py` does. Use invented text; `oov` is a fake returning a fixed set.
  - `test_low_probability_word`: the segment `" the quick test"` with word `" test"` p 0.2 gives one suspect `{segment: 0, start: 11, end: 15, text: "test", kind: "other", score: 0.8, source: "heuristic"}` (score within 1e-9).
  - `test_near_vocabulary`: vocab `["Sway", "Claude Code"]` and the text `"open sway and claud code"` give suggestion `"Claude Code"` on `"claud code"`. No suspect on `"sway"` (equal after lowercasing).
  - `test_out_of_dictionary_skips_arabic_and_vocab`: an `en` draft `"zorbly مرحبا NixOS"`, with `oov` returning `{"zorbly", "nixos"}` and vocab `["NixOS"]`. Exactly one suspect, on `zorbly`. The fake receives no Arabic token.
  - `test_silence_stock_repeat_script`: four segments (no_speech 0.9; `" Thank you."`; `" go go go go"`; an `en` segment with Arabic letters) give kinds `hallucination, hallucination, hallucination, language`.
  - `test_no_conf_and_no_segments`: a draft without `conf` and a draft with `segments=[]` both return lists without raising; the second has `segment: None`.
  - `test_ids_stable_and_one_per_span`: running twice gives the same ids. A span hit by two rules appears once, with the higher score.
- [ ] **Step 2: Run** `python3 -m unittest discover -s modules/nixos/features/dictation-lab/tests -p 'test_heuristics.py' -v`. Expected: FAIL (`AttributeError: … heuristic_suspects`).
- [ ] **Step 3: Implement** the interfaces above. Levenshtein is a plain stdlib DP.
- [ ] **Step 4: Run** the same command. Expected: all pass. Then run the whole `tests/` dir: still green.
- [ ] **Step 5: Commit** `dictation lab: heuristic suspect rules`.

### Task 2: `dictate-lab analyse` and the suspect store

**Files:**
- Modify: `dictate-lab.py` (store, hunspell wrapper, `analyse` subcommand)
- Create: `tests/test_analyse.py`

**Interfaces:**
- Consumes: `heuristic_suspects` (Task 1).
- Produces:
  - `iter_drafts(data_dir) -> Iterator[tuple[str, dict, list[dict]]]`: yields `("<origin>/<id>", meta, segments)`. Skips `.tmp` dirs and unparsable meta; torn jsonl lines are skipped by `_jsonl`.
  - `append_unique(data_dir, name: str, rows: list[dict], key="id") -> int`: under the flock, reads the existing keys of `<data_dir>/<name>`, appends the new rows, returns the count added. `matches.jsonl` uses `key="draft"`.
  - `hunspell_oov(hunspell: str | None, dic: str | None) -> Callable[[list[str]], set[str]]`: runs `hunspell -l -d <dic>` with the words on stdin and returns the set printed. With either argument `None`, the callable returns `set()`.
  - `analyse(data_dir, vocab, oov, now_ms, redo=False) -> dict`: returns `{"drafts": n_analysed, "added": n_suspects}`. It skips drafts whose `received_ms` equals the one in `analysed.json`, unless `redo`. Then it rewrites `analysed.json` atomically (tmp + `os.replace`).
  - CLI: `analyse --data-dir D --vocab FILE.json [--hunspell PATH --dict PATH] [--all]`. It logs `analysed N drafts, M new suspects`.

- [ ] **Step 1: Failing tests** in `test_analyse.py`. Build a lab tree in a temp dir with `normalize`-shaped files.
  - `test_analyse_appends_then_is_idempotent`: the first run returns `added > 0`. A second run returns `{"drafts": 0, "added": 0}`, and the file line count is unchanged.
  - `test_reupload_is_reanalysed_without_duplicates`: bump `received_ms`; `drafts == 1`, and lines are added only for new spans.
  - `test_skips_tmp_and_broken_meta`: a `x.tmp` dir and a dir with `meta.json = b"{"` are ignored.
  - `test_append_unique_under_concurrency`: 8 threads append the same 50 rows; the file ends with 50 lines.
  - `test_hunspell_oov_real`: `skipUnless(os.environ.get("DICTATE_TEST_HUNSPELL_DICT"))`. `["hello", "zorblyx"]` gives `{"zorblyx"}`.
  - `test_analyse_logs_no_text`: capture stderr for a draft whose text holds the marker `"QUIXOTIC-MARKER"`; the marker is absent from the output.
- [ ] **Step 2: Run** the test file. Expected: FAIL (missing `analyse`).
- [ ] **Step 3: Implement** the interfaces and wire the subparser into `main()`.
- [ ] **Step 4: Run** the whole `dictation-lab/tests` dir. Expected: all pass (the hunspell test skips).
- [ ] **Step 5: Commit** `dictation lab: analyse drafts into suspects.jsonl`.

### Task 3: Lab API for mining

**Files:**
- Modify: `dictate-lab.py` (`make_server`: an `/api/` dispatch ahead of the inbox routing)
- Modify: `tests/test_inbox.py` (new class `Api`)

**Interfaces:**
- Consumes: `iter_drafts`, `append_unique`, `suspect_id` (Tasks 1–2).
- Produces:
  - `GET /api/drafts?since=<ms>` → 200 `{"drafts": [{draft, created_ms, duration, tier, app, lang, text, segments: [{i, text, ok}]}]}` for `created_ms >= since`. A missing or non-integer `since` is 400.
  - `POST /api/mined`, with body `{"suspects": [...], "matches": [...]}` and `Content-Length` required (limit 16 MiB) → 200 `{"added": n}`.
    - Each suspect must have `source == "agent-diff"`, a `draft` that exists in the tree, `segment` int or null, `0 <= start < end` ints, `kind` in KINDS, and `suggestion` str or null.
    - The server recomputes `id` and `found_ms`, and takes `text` from the stored segment.
    - Any invalid suspect or match makes it 400, and nothing is written.

- [ ] **Step 1: Failing tests** in `Api`, using the plan 2 test server with a fake `PeerCheck`:
  - `test_drafts_since`: two drafts, at 1000 and 5000; `since=2000` returns only the second, with its segments.
  - `test_api_refuses_strangers`: a peer check that denies gives 403 on both routes, and no file is created.
  - `test_mined_validates_and_dedups`: a valid post gives `added: 1`, and the same post again gives `added: 0`. A suspect with `source: "claude"`, or with an unknown draft, gives 400, and `suspects.jsonl` is unchanged.
  - `test_mined_text_from_store`: the posted `text` is ignored; the stored line has the segment slice.
- [ ] **Step 2: Run** `test_inbox.py`. Expected: the new tests fail (404).
- [ ] **Step 3: Implement**, keeping the inbox routes untouched.
- [ ] **Step 4: Run** the whole dir. Expected: green.
- [ ] **Step 5: Commit** `dictation lab: API for drafts and mined suspects`.

### Task 4: `dictate-lab mine`

**Files:**
- Modify: `dictate-lab.py` (`mine` section and subcommand)
- Create: `tests/test_mine.py`

**Interfaces:**
- Consumes: `tokens`, `norm`, and the two Task 3 routes.
- Produces:
  - `sent_messages(sessions_dir: Path, since_ms: int) -> list[tuple[int, str]]`: `(ts_ms, text)`. It reads `*/*.jsonl` with mtime ≥ since, keeping lines with `type == "user"`, `userType == "external"`, a falsy `isMeta` and a falsy `isSidechain`.
    - Content is a string, or a list whose `text` items are joined.
    - It drops lists holding `tool_result`, and text starting with `<`.
    - Unparsable lines are skipped.
  - `match(draft: dict, messages) -> tuple[int, str, float] | None`: best `(ts_ms, text, coverage)` in the window, or `None`. Drafts of fewer than 4 words give `None`.
  - `diff_suspects(draft: dict, message: str) -> list[dict]`: suspect dicts without `id`, `text` or `found_ms`.
    - Align `norm` keys with `difflib.SequenceMatcher(autojunk=False)`, restricted to the message region between the first and last matching blocks.
    - `replace` or `delete` with ≤ 4 words a side: kind `punct` if the norms agree, `term` if the suggestion has an inner capital, a digit or one of `-_./`, else `other`. Score 0.9 (delete: 0.6).
    - Equal norms whose raw tokens differ: `punct`, 0.3.
    - A span is the draft-side token range, clipped to the segment of its first token; the suggestion is the message-side words.
  - `mine(lab_url, sessions_dir, days, now_ms, timeout=20) -> dict`: returns `{"drafts", "matched", "added"}`.
  - CLI: `mine --lab URL --sessions DIR [--days 3]`. It logs counts only; an unreachable lab logs a line and exits 0, so the next timer retries.

- [ ] **Step 1: Failing tests** in `test_mine.py`, with fixtures written as session jsonl (invented text):
  - `test_sent_messages_filters`: lines for a string message, a text-list message, a tool_result, `isMeta`, `isSidechain`, `<command-name>…` and a torn line. Only the first two are returned, with their timestamps.
  - `test_match_window_and_coverage`: the draft `"please open the sway config and fix the bar"` matches the edited message sent 5 min later (coverage ≥ 0.6). It doesn't match the same message sent 2 h later, an unrelated message, or the two-word draft `"yes please"`.
  - `test_diff_suspects`: the draft `"restart the hormonia cache on butter nut"` against the message `"Restart the harmonia cache on butternut."` Two suspects: `hormonia → harmonia` (`other`) and `butter nut → butternut.` (`other`). The case-only `restart`/`Restart` gives one `punct` at 0.3. Offsets index the draft segment text.
  - `test_big_rewrite_ignored`: a 6-word replacement yields nothing.
  - `test_mine_end_to_end`: the Task 3 server on a temp tree with one draft and one session file. The first `mine` gives `added ≥ 1` and writes `matches.jsonl`; the second gives `added: 0`.
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces.
- [ ] **Step 4: Run** the whole dir. Expected: green.
- [ ] **Step 5: Commit** `dictation lab: mine agent prompts for your edits`.

### Task 5: `dictate-lab census`

**Files:**
- Modify: `dictate-lab.py` (`census` subcommand)
- Create: `tests/test_census.py`

**Interfaces:**
- Consumes: `iter_drafts`, `suspects.jsonl`, `matches.jsonl`.
- Produces:
  - `census(data_dir, weeks=8, origin=None, tier=None, lang=None, now_ms=None) -> dict`:
    - `{"weeks": [{week: "2026-W47", drafts, words, heuristic_per_100w, agent_diff_per_100w, matched}], "kinds": {kind: n}, "personal_apps": {app: n}}`.
    - The week is the local ISO week of `created_ms`, newest last. Words = `len(tokens(meta.text))`. Rates are rounded to 1 decimal, and are 0 with no words.
  - `pairs(data_dir, min_count=2) -> list[tuple[str, str, int]]`: `(text, suggestion, n)` from agent-diff suspects, most frequent first.
  - CLI: `census [--weeks N] [--origin O] [--tier T] [--lang L] [--pairs]`.
    - It prints a fixed-width table, then a `by kind:` line ordered by count, then `personal drafts seen in agent sessions:` with app ids.
    - With `--pairs`, it adds the pairs list.

- [ ] **Step 1: Failing tests:**
  - `test_rates`: two drafts in one week, 100 words in total, with 3 heuristic and 2 agent-diff suspects, give `heuristic_per_100w == 3.0` and `agent_diff_per_100w == 2.0`.
  - `test_filters`: `tier="work"` excludes the personal draft's words and suspects.
  - `test_personal_apps`: a match with tier personal and app `org.example.chat` gives `{"org.example.chat": 1}`.
  - `test_pairs`: the same pair three times gives `[("hormonia", "harmonia", 3)]`.
  - `test_default_output_has_no_text`: the CLI output without `--pairs` contains no suspect text (marker check, as in Task 2).
- [ ] **Step 2: Run** the test file. Expected: FAIL.
- [ ] **Step 3: Implement** the interfaces.
- [ ] **Step 4: Run** the whole dir. Expected: green.
- [ ] **Step 5: Commit** `dictation lab: census on the command line`.

### Task 6: Nix wiring (package, timers, checks)

**Files:**
- Modify: `modules/nixos/features/dictation-lab.nix`
- Modify: `modules/nixos/features/dictation.nix`

**Interfaces:**
- Produces:
  - `packages.<system>.dictate-lab`, the current `writePython3Bin` derivation moved into `perSystem`. The module uses `self.packages.${pkgs.stdenv.hostPlatform.system}.dictate-lab`.
  - **On butternut (`dictation-lab`):**
    - The package goes into the user's `home.packages`, for `census`.
    - `systemd.user.services.dictation-lab-analyse` (oneshot, `Nice = 10`) runs `analyse --data-dir … --vocab ${vocabFile} --hunspell ${pkgs.hunspell}/bin/hunspell --dict ${pkgs.hunspellDicts.en_US}/share/hunspell/en_US`, where `vocabFile = pkgs.writeText "dictation-vocabulary.json" (builtins.toJSON self.dictationVocabulary)`.
    - `timers.dictation-lab-analyse` runs `OnCalendar = "hourly"`, `Persistent = true`.
  - **In `dictation`, when `labUrl != null`:**
    - `systemd.user.services.dictate-lab-mine` (oneshot) runs `${dictate-lab}/bin/dictate-lab mine --lab ${cfg.labUrl} --sessions %h/.claude/projects --days 3`.
    - Its timer is hourly with `RandomizedDelaySec = "5m"`.
    - The package is not added to `home.packages` here.
  - `checks.dictation-lab` adds `pkgs.hunspell` and sets `DICTATE_TEST_HUNSPELL_DICT=${pkgs.hunspellDicts.en_US}/share/hunspell/en_US`, so the real-hunspell test runs.

- [ ] **Step 1: Edit both modules**, then `git add -N` any new file.
- [ ] **Step 2: Run** `nix build --no-link .#checks.x86_64-linux.dictation-lab .#checks.x86_64-linux.dictation-capture`. Expected: success, and the log shows `test_hunspell_oov_real ... ok`, not skipped.
- [ ] **Step 3: Check the units.**
  - Run `nix eval --raw .#nixosConfigurations.butternut.config.home-manager.users.<user>.systemd.user.services.dictation-lab-analyse.Service.ExecStart` and the same for `hazel … dictate-lab-mine`. Expected: both store paths end in `/bin/dictate-lab`, with the flags above.
  - Take the username from `nix eval --raw .#nixosConfigurations.butternut.config.preferences.user.name`.
- [ ] **Step 4: Run** `just check` (or the raw commands): fmt, lint and eval-all are OK (niri-desktop-vm skipped). Then `nix build --no-link .#nixosConfigurations.butternut.config.system.build.toplevel`.
- [ ] **Step 5: Smoke-test on butternut** without printing text:
  - Run `result/bin/dictate-lab analyse` against a copy of the real lab dir in the scratchpad. Only the count line is shown.
  - Run `census` with no flags.
  - Report the counts only.
- [ ] **Step 6: Commit** `dictation lab: analyse and mine timers, dictate-lab package`. Run `nix run .#fleet -- affects` for the PR body.
