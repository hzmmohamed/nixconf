# Dictation training lab: design

Status: design approved (2026-11-25), including the §5.8 UX calls. Nothing built yet.
Scoping: `2026-11-24-pollen-keyboard-audit-and-ideas.md` §3 (this doc
supersedes its §3.4 pick and §3.5 privacy section where they differ).

## 1. Intent

Every dictation (Pollen on the phone, `dictate` on hazel and butternut) is
collected in one place, scanned for likely transcription errors, and the
suspects are served as short correction rounds: a game. Each answer becomes
data that makes dictation better:

1. **Vocabulary**: words Whisper keeps getting wrong go into its initial
   prompt (public `modules/dictation-vocabulary.nix` for technical terms,
   a private list for names).
2. **Replacement rules**: recurring mis-hearings fixed after transcription
   (private, outside git; works for Parakeet too, which takes no prompt).
3. **A dataset** (audio snippet + corrected text + language) for
   fine-tuning later.

The user cannot yet say which errors bother them most, so the lab's first
job is a **census**: every suspect is labelled by kind, and the counts tell
where effort goes next (vocabulary vs rules vs fine-tuning).

## 2. Goals, non-goals, anti-goals

Goals:
- All drafts from both phone and laptops in one tree on butternut, kept
  past the 7-day draft window.
- Suspects from three sources: cheap heuristics (all drafts), agent-prompt
  edit mining (free ground truth), Claude (work-tier drafts only).
- A correction game that takes a minute: a round of ~10 cards, playable on
  the laptop and in the phone's browser, later as a Pollen screen.
- Corrections turn into reviewed vocabulary diffs, private rules served to
  every client, and a dataset manifest.
- A measurable result: suspects and corrections per 100 words, per week,
  per source; it should fall.

Non-goals:
- Recording edits in arbitrary apps (impossible: text is pasted into other
  apps and edited with other keyboards). Agent prompts are the exception
  (§5.3).
- Real-time correction while dictating. The lab is offline, after the fact.
- Fine-tuning now. It is the last phase, gated on a few hundred
  corrections.

Anti-goals (failure even if it works):
- **Personal dictation reaching a commercial model.** The tier rule (§3)
  is enforced in code, fail-closed, not by convention.
- Any transcript, audio, correction, name or replacement rule in git
  (public repo). Only vocabulary words the user accepts one by one.
- Dictation getting slower or Pollen's panel getting busier during a
  recording. All lab work happens after delivery.
- A lab that nags: no notifications; the game waits until it is opened.

## 3. Privacy tiers (decided with the user)

Every draft carries `tier`:

| Tier | Who may read the text | How it is set |
|---|---|---|
| `work` | heuristics, open-weight models, **Claude** | target app is on the work list, or the user flips the toggle |
| `personal` | heuristics and open-weight models on the user's hardware only | **default**: any app not on the work list, unknown apps, no app |
| incognito (existing) | nobody: no draft is kept (phone), nothing uploaded | the field asks for no personalised learning |

Rationale (user): Claude already sees most work prompts (they are typed into
Claude Code and T3); personal text stays under the standing open-weight-only
rule. Unlisted defaults to personal (user's choice): a forgotten flag costs
analysis quality, never privacy.

- **Classification at record time.** The phone knows the target package
  (`DictationIme.kt:148`, `attribute.packageName`); the desktop knows the
  focused window's `app_id` (`dictate-stream.py:625`, `focused_app()`).
  Both store it in the draft (`app`) with the resulting `tier`.
- **Work lists** are public config (app ids are not personal):
  `preferences.dictation.workApps` (desktop app_ids; starting set: kitty,
  VSCodium, the T3 desktop app) and `preferences.dictation-server.phone.workApps`
  (Android packages; starting set: the T3/Claude mobile clients and
  terminal apps actually installed; the builder lists them from the
  phone with the user). Browsers stay personal: the domain is not
  visible on the phone.
- **Override.** Pollen: a small tier chip in the panel (shows the guess,
  tap flips it for this draft). Desktop: `dictate tier work|personal`
  (next session only; also in `dictate menu`) and the overlay shows the tier. No new key binding (bindings only when
  the user asks). The game can also flip a draft's tier, and suggests
  adding an app to the work list when the user keeps promoting it (user
  confirms; it is a config change).
- **Enforcement.** The analyser builds the Claude batch from
  `tier == "work"` only; a missing or unknown tier counts as personal. A
  test feeds a personal draft and asserts no Claude call is made.

## 4. Approaches (user picked 1)

1. **Butternut hub, web game first (picked).** Uploads to a tailnet-only
   inbox; analysis on butternut; the game is one HTML page over a small
   JSON API, playable on the laptop and in the phone browser; a Pollen
   screen later on the same API. One copy of the data, rules in one
   place, playable soon. Cost: the first phone experience is a browser
   page.
2. **Butternut hub, Pollen game first.** Same backend, native game first.
   Nicer on the phone, but more Kotlin before anything is playable and a
   desktop view is still needed for laptop drafts.
3. **Mining only, no game.** Agent-prompt diffs + Claude producing a
   weekly vocabulary diff. Fastest, no service, but laptop work drafts
   only, no audio, no phone, no game.

Dropped earlier: a phone-only lab (data split across devices).

## 5. Design

### 5.1 Data flow

```
 Pollen (phone) ──upload on tailnet──┐
 dictate (hazel) ──after session─────┼──> dictation-lab inbox (butternut, tailnet only)
 dictate (butternut) ──localhost─────┘        │
                                              v
                          ~/.local/state/dictation/lab/   (butternut, user-owned)
                              drafts/<origin>/<id>/  meta.json, segments.jsonl, audio.opus
                              suspects.jsonl   corrections.jsonl   private.json
                                              │
     dictate-lab analyse (timer) ─ heuristics · Claude(work only) · [open model later]
     dictate-lab mine (every agent host) ─ journal ↔ sent agent messages
                                              │
     lab API: /api/round  /api/audio/…  POST /api/answer  /api/census  /private.json
                                              │
     game page (laptop + phone browser), later Pollen screen
                                              │
     dictate-lab apply ─ vocabulary diff (user reviews, commits) · private.json · dataset.jsonl
```

### 5.2 Capture and upload

Draft bundle (one shape for both sides; existing fields keep their names):
`meta.json` gains `app`, `tier`, `origin` (`phone`/`hazel`/`butternut`),
`prompt_sha` (hash of the Whisper prompt used); segments gain
`avg_logprob`, `no_speech_prob`, and token probabilities where available.

- **Confidence**: request `response_format=verbose_json` instead of `json`
  (`WhisperClient.kt:59`, `dictate-stream.py:557`) and keep the extra
  fields. *Builder verifies the pinned whisper.cpp server returns
  per-token probabilities*; if only per-segment values exist, use those.
  Parakeet (on-phone) gives no confidence: its drafts get heuristics only.
- **Phone**: after a draft is delivered (not incognito), Pollen uploads it
  when the lab is reachable (tailnet up, `lab` URL in the profile);
  `meta.json` gets `uploaded: true` on the server's ack. `prune()` skips
  drafts not yet uploaded, so a week without butternut loses nothing
  (bounded by a cap, e.g. 200 MB, oldest uploaded first). Upload uses the
  existing OkHttp client; WorkManager or a simple retry at next delivery
  (builder's call).
- **Desktop**: `dictate-stream.py` posts the finished draft to the inbox at
  the end of a session (butternut: localhost). A user timer
  (`dictate-lab sync`, hourly) retries anything without `uploaded`.
- **Inbox**: `POST /inbox/<origin>/<id>` with the bundle as multipart;
  idempotent (same id replaces); rejects drafts marked incognito.

### 5.3 Finding suspects

`dictate-lab analyse` (Python, stdlib; a user timer on butternut, plus on
demand) appends to `suspects.jsonl`:
`{id, draft, segment, start, end, text, suggestion?, kind, source, score}`.

`kind`: `term` (name/technical word), `punct`, `language` (wrong language
or script), `hallucination` (text over silence, "Thank you."), `grammar`,
`other`. `source`: `heuristic`, `agent-diff`, `claude`, later `local-llm`.

Sources, cheapest first:
1. **Heuristics** (all tiers): low token/segment probability; words within
   edit distance 1-2 of a vocabulary or private-vocabulary entry; words
   outside hunspell en/ar dictionaries (hunspell from nixpkgs); high
   `no_speech_prob` with text; repeated n-grams within a segment
   (Whisper loops).
2. **Agent-prompt edit mining** (`dictate-lab mine`, all tiers: it only
   diffs locally, no model). Runs on every host that has agent sessions
   (butternut, hazel; fern later). It fetches recent drafts' text from the
   lab API, reads the user's sent messages from `~/.claude/projects/*/*.jsonl`
   (T3's Claude threads land there too), matches each draft to a message
   sent within ~30 min with high similarity (verified on butternut: every
   long dictation of the past week appears in a sent message), and posts
   word-level diffs back as suspects with the user's edit as the
   suggestion. These are near-certain; the game shows them as "you
   changed this: make it a rule?". A personal-tier draft that turns up in
   an agent session is a hint to add its app to the work list (shown, not
   applied). OpenCode sessions: later, same interface.
3. **Claude** (work tier only, §3): `claude -p` on butternut, no tools,
   JSON output, batches of drafts with the current vocabulary as context;
   asks for spans that are likely mis-transcriptions with a suggestion and
   kind. Model configurable; runs at most nightly. *Builder confirms the
   exact flags for a tool-less, non-interactive JSON run on the pinned
   Claude Code.*
4. **Open-weight model** (personal tier, phase 6): same prompt against an
   OpenAI-compatible endpoint (peacelily llama-swap once redeployed). The
   analyser accepts only endpoints on an explicit allowlist for personal
   drafts.

Suspects are deduplicated per span; a span the user marked correct is
never asked again, and the same (from → to) pair seen N times is grouped
into one card ("this happened 7 times").

### 5.4 The game

One HTML file (no build step, served by the lab), themed from the fleet
palette like other pages. A **round** is up to 10 cards, highest-value
first (agent-diff, then repeated patterns, then high score).

```
 ┌──────────────────────────────────────────┐
 │ round 3/10 · work · kitty · 2 days ago   │
 │                                          │
 │ "…deploy it to [butter nut] after the…"  │
 │                         ▶ play 2.1 s     │
 │ suggestion: butternut   (term, heuristic)│
 │                                          │
 │ [ Accept ]  [ Edit… ]  [ It's right ]  [ Skip ] │
 │ after a fix:  learn word · rule · just this once │
 └──────────────────────────────────────────┘
   streak 4 days · 38 fixed this week · census ▸
```

- **Answers**: accept the suggestion, edit it, "it's right" (false
  positive, never asked again), skip. After a fix, one tap says what it
  teaches: *learn word* (vocabulary candidate; the user picks public or
  private), *rule* (private replacement from → to), *just this once*
  (dataset only).
- Each card plays the segment's audio (offsets are known on both sides;
  the API cuts the snippet).
- Light game layer: round progress, a streak, weekly counts. No
  notifications.
- **Census** view: suspects and confirmed errors by kind, source, origin
  and language, per week, per 100 words. This is the answer to "which
  errors matter".
- Tier flip on the card (§3).
- Keyboard shortcuts on the desktop page (a/e/r/s); thumb-sized buttons on
  the phone.

### 5.5 Turning corrections into improvements

`corrections.jsonl`: `{suspect, draft, segment, from, to, kind, teaches,
source, ts}` (`teaches` ∈ `word-public`, `word-private`, `rule`, `once`,
`none`).

`dictate-lab apply` (run by the user, or proposed weekly):
- **Public vocabulary**: prints a diff for `modules/dictation-vocabulary.nix`
  (adds ranked by correction count; suggests removals of words never
  corrected, since Whisper's prompt budget is ~224 tokens). The user or an
  agent commits it; nothing writes to the repo automatically.
- **Private file** `lab/private.json` `{vocabulary: [...], replacements:
  [{from, to, lang, whole_word}]}`, outside git. Served at
  `/private.json` by the lab (tailnet only). Pollen fetches it with the
  profile and appends the words to the prompt and applies the rules in
  `clean()`; `dictate` does the same (butternut reads the file, hazel
  fetches and caches it). Replacements apply to both engines.
- **Dataset** `lab/dataset.jsonl`: `{audio: <snippet path>, text, lang,
  origin, tier}`, snippets cut from the corrected segments and kept
  indefinitely. Personal-tier items stay usable for local fine-tuning
  only.

The desktop's Whisper prompt is empty today (`dictation.nix:423`); the
first phase defaults it to the fleet vocabulary, as the phone already does.

### 5.6 Service and placement

- New feature `flake.nixosModules.dictation-lab` (butternut only): a
  Python stdlib HTTP server running **as the user** (it writes under
  `~/.local/state/dictation/lab/`; separate from `dictation-server`, which
  runs as a dynamic user), the analyse timer, and the page. Port e.g.
  8181, reachable on `tailscale0` only: not added to
  `preferences.trustedNetworks`. Each request's peer is checked with the
  Tailscale local API (`whois`) against the user's own devices; a Tailscale
  ACL (tailnet-as-code) is the second fence.
- The `dictation` feature gains the client bits: tier/app capture, upload,
  `dictate-lab sync` and `mine` timers, `workApps`, the private-file fetch.
- `dictation-server`'s phone profile gains `lab` (URL) and `workApps`;
  `checks.phone-profile` covers the new keys.
- `dictate-lab` is one Python script with subcommands (`serve`, `analyse`,
  `mine`, `sync`, `apply`, `census`), packaged like the other dictation
  scripts.

### 5.7 Retention

- Lab drafts: text and metadata kept indefinitely; full audio kept 90 days
  (Opus, ~180 KB/min), then only snippets of corrected segments (dataset).
  Arabic audio kept longer (default: indefinitely), since that is where
  fine-tuning would pay off.
- Phone: unchanged 7 days, but never prunes a draft before it is uploaded.
- Deleting a draft in the game deletes it everywhere in the lab.

### 5.8 UX decisions (approved with the user, 2026-11-25)

Reviewed as a clickable walkthrough (tier chip, entry points, an example
round, census, outcomes); the user accepted every default:

| | Decision | Rejected alternative |
|---|---|---|
| a | The tier chip is always visible in Pollen's top row (next to the language toggle); Work is drawn in ink (outlined), Personal is plain with a lock glyph; incognito fields show no chip | chip only when the app is on neither list |
| b | No notifications: a "Lab · N cards" row in the Pollen app and a desktop launcher entry ("Dictation lab") are the only entry points and the only places a count appears | weekly digest notification |
| c | Rounds of 10 cards with a finish and a round summary (fixed / were right / skipped / new rules and words) | an endless queue |
| d | A light game layer: a day streak and a weekly fixed-count; no points or levels | none, or more |
| e | New words default to the private list; the lab suggests public for technical-looking words; the user picks per word | ask every time with no default |
| f | Repeated identical edits still produce a card ("you changed this N times") with *Make a rule* pre-selected; no automatic rules | auto-rule after 3 identical edits |
| g | Audio plays on tap only | autoplay per card on the laptop |
| h | The phone plays in the browser until the native Pollen screen exists | wait for the native screen |

Card anatomy (for the page and later the Pollen screen): meta row (tier
tag, tappable to flip; app; when; kind; "found by"), the sentence with the
suspect span marked, a play button over the segment's audio, one line of
why it was flagged (personal cards say "checked on your machines only"),
the suggestion, then Accept / Edit / It's right / Skip (`a` `e` `r` `s` on
the laptop). After a fix: *Learn the word* (then public or private) /
*Make a rule* / *Just this once*, with the likely one outlined. Cards
order: agent-prompt edits, then repeats, then by score. Census: the
per-100-words trend first, then confirmed mistakes by kind (largest in
ink), filterable by origin, tier and language.

## 6. Phases

1. **Capture**: `tier`/`app`/`origin`/`prompt_sha` in drafts on both
   sides, the Pollen tier chip, `dictate tier`,
   `verbose_json` confidences, desktop prompt default. No new service.
2. **Hub**: `dictation-lab` feature with inbox, phone upload, desktop
   upload + sync timer, retention.
3. **Suspects**: heuristics and agent-prompt mining; census on the
   command line.
4. **Game**: the web page with rounds, audio, answers, census view.
5. **Claude + apply**: Claude pass for work drafts; `dictate-lab apply`,
   `private.json` consumed by Pollen and `dictate`.
6. **Later**: Pollen game screen; open-weight pass for personal drafts
   (peacelily); dataset export and fine-tuning experiments (WER on a
   held-out week, before/after).

Each phase is a small PR; phases 1-3 are useful before the game exists
(census + mined rules).

## 7. Left to the builder

- Exact work-list contents (with the user, from the installed apps).
- whisper.cpp `verbose_json` fields on the pinned build; Claude Code flags
  for a tool-less JSON run.
- Upload scheduling on Android (WorkManager vs retry-on-delivery).
- Heuristic thresholds (tune on the census).
- Matching thresholds for mining (similarity, time window).
- Page styling within the fleet palette.

## 8. Calls made in this design (not discussed; check these)

- The lab is its own feature (`dictation-lab`, runs as the user), not part
  of `dictation-server` as the scoping report suggested.
- Peer check via Tailscale `whois` in addition to tailnet-only binding.
- Mining runs on every agent host and posts diffs to the hub, rather than
  copying session logs to butternut.
- Private vocabulary and rules are served as `/private.json` and fetched by
  clients, rather than baked into the store-built `profile.json`.
- Retention: lab text forever, full audio 90 days, Arabic audio forever,
  corrected snippets forever; phone never prunes an un-uploaded draft.
- Browsers count as personal; no new key bindings; no notifications.
- Claude pass at most nightly, in batches; model configurable.
