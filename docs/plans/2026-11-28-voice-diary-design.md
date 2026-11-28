# Voice diary: design

Status: **approved by the user, 2026-11-28**. Shaped in
`2026-11-28-knowledge-and-diary-brainstorm.md` §A. "Decided" = the user's choice in that
conversation; "my call" = Claude's, open to correction.

## 1. Intent

A diary kept mostly by voice, in mixed Egyptian Arabic and English, that
the user can look back into: reread and listen to old entries, reflect on
them, see mood over recent weeks, connect memories to photos, and ask what
they said a year ago. Speaking is the chosen mode, and hearing entries back
in one's own voice is part of the point, not a fallback to the transcript.

Existing entries are spread over paper, notebooks, voice memos and a notes
app, where nothing can be found. The diary replaces these for new entries
and takes the old ones in by backfill.

It is **not an inbox**: entries are never processed or cleared. It is its
own system, separate from the knowledge/media system (brainstorm §B,
designed in a sibling thread). It lives in **Pollen**, the phone
companion app (`apps/phone/`).

## 2. Goals, non-goals, anti-goals

**Goals**
1. Recording is faster than grabbing a scrap of paper: one tap from the
   lock screen, Quick Settings or a widget, works with the screen off and
   offline, through earbuds.
2. Every entry is kept forever: audio, transcript, mood, photos, two
   dates (recorded, and what it is about).
3. Listening is first-class: an entry plays in the user's voice with the
   transcript following, and any sentence can be tapped to play from there.
4. A weekly review that the user tells first (§5.6).
5. Mood over the weeks from the user's own taps, gaps filled by a marked
   model guess.
6. Looking back: search, Ask, themes, "a year ago today", places to go
   back to, events with photos.
7. Backfill of everything kept so far: paper and notebook read aloud and
   photographed, old voice memos and notes-app text imported with their
   original dates.
8. Transcripts improve over time: re-run when better open models for
   Egyptian Arabic appear, without losing anything.

**Non-goals (v1)**
- Typing or handwriting as a main input. Voice first, decided; a typed
  entry is possible but nothing is designed around it.
- A desktop app. Reading on the laptop is a later surface (my call).
- Sharing entries with anyone.
- Using diary audio to train or fine-tune models (the dictation lab).
  Possible later, only by explicit per-entry choice (my call).
- Reading the attention tracker's location or check-ins (§8, seam).

**Anti-goals** (would make it a failure even if it works)
- Any commercial model, or any agent building this, ever reading an entry.
- The diary turning into a task list or inbox to clear.
- A model telling the user's story for them: drafting the weekly review
  first, naming feelings without the user's taps, summarising without
  sources.
- Guilt mechanics: streaks, missed-day counters.
- Losing an entry to a dead phone, a dead server or a bad transcription.

## 3. Constraints (non-negotiable)

1. **Model boundary**: only open-weight models on the user's hardware
   (peacelily; butternut as fallback) process entries. Agents design and
   build against synthetic data; they never see real entries. Same rule as
   attn (`2026-11-25-attention-tracker-design.md` §3.1).
2. **No plaintext at rest anywhere**, application-level encryption on the
   phone, in S3 and on peacelily, regardless of disk encryption (attn §3.2).
3. **Key custody** as attn §3.3: nothing that decrypts the diary is
   readable by the owner's Unix user on an agent host.
4. **Capture never depends on the network or peacelily.**
5. **Raw is kept forever and immutable** (attn §3.7), except for the
   deliberate purge (§5.16).
6. Stack as attn: Kotlin in Pollen, Bun + Effect v4 for the server side,
   personal AWS eu-central-1, Nix builds everything but the APK.
7. nixconf is public: diary code may live there, but never real data,
   keys, hostnames beyond what is already public, or personal word lists.
8. Phone-local speech recognition (Parakeet) is English only; Arabic needs
   Whisper on peacelily, which is not yet redeployed.

## 4. Approaches

Decided: **A**.

| | Approach | Trade-off | Verdict |
|---|---|---|---|
| A | **attn's pattern as a separate system**: Pollen encrypts and queues each entry, uploads to its own immutable S3 prefix; a diary service on peacelily pulls, transcribes, indexes and serves Pollen over Tailscale; Pollen keeps an encrypted local copy of recent entries | most work up front, waits on peacelily; proven privacy model, off-site immutable copy, the Kotlin frame-log writer is shared with attn's Pollen module, re-transcription = re-run on kept audio | **chosen** |
| B | Home only over Syncthing: encrypted files in a synced folder, processed at home | no cloud; no off-site or undeletable copy until a separate backup; syncs only when phone and home are both up | rejected |
| C | Phone-first: everything on the phone, server stateless | simplest, fully offline; one phone holds decades of diary, weaker search and Ask; backups lead back to A or B | rejected |

Why A: a diary is meant to last decades, so the off-site, undeletable copy
matters more here than anywhere else; attn already pays for most of the
design.

Other decisions made along the way, with the rejected options:

| Topic | Decided | Rejected |
|---|---|---|
| Weekly review | **C: the user tells the week first, then sees what the entries said, then adds** | A: model drafts, user reacts (the model's framing steers the story); B: fresh telling only (misses early-week things) |
| Mood | **C: optional self-rating tap wins; a model guess fills gaps, marked as a guess** | model only (unreliable in mixed Arabic/English, judges feelings for the user); self only (gaps) |
| Photos | **both ways**: attach from an entry, or "tell this one" from a photo; plus albums (events) | — |
| Links to knowledge | **one way plus send** | two-way (personal life leaks into a processing system); none |
| Resurfacing | **show everything**, hard days included | lean toward good entries + per-entry "don't bring back" mark |
| Nudges | **welcome**: daily and weekly | none |
| Deletion | **hide in everyday use, plus a rare deliberate purge** from a break-glass role unlocked from the vault (§5.16) | hide only (everything spoken stays forever); per-entry keys destroyed to erase (losing the key store loses the diary) |
| attn's evening check-in | **one evening moment**: one nudge, one screen; attn's chips (place, energy, day shape) go to attn, the recording goes only to the diary; attn keeps no check-in audio and its spoken check-in is not built | both with one nudge (two stores); fully separate (two nudges, two recordings) |

## 5. Design

### 5.1 Overview

```
 phone: Pollen ─ Diary module                          peacelily: diary-brain
 ┌──────────────────────────────────────┐             ┌──────────────────────────────────┐
 │ record (tile/widget/lock, screen off)│             │ pull → verify → decrypt          │
 │ entry = audio (Opus) + taps + photo  │             │ Whisper (multilingual, timed)    │
 │   pointers + dates → frame log (age  │──upload──►  │ encrypted DuckDB: entries,       │
 │   to brain + vault, signed, Keystore)│   S3 diary/ │  sentences, mood, mentions,      │
 │ local cache (Keystore AES, recent)   │  immutable  │  events, embeddings, FTS         │
 │ screens: Home, Entry, Review, Ask,   │◄─Tailscale──│ HttpApi: timeline, entry, search,│
 │   Events, Places, Backfill           │   API       │  ask, review, themes, audio      │
 │ local nudges (AlarmManager)          │             │ ModelGateway → llama-swap (open) │
 └──────────────────────────────────────┘             └─────────────┬────────────────────┘
                                                                    │ read-only API
                                                       Immich (butternut → peacelily):
                                                       asset search by date/GPS, thumbnails
```

### 5.2 Where the code lives (my call)

- **Pollen Diary module**: `apps/phone/` in nixconf, a new package next
  to `ime`, `session`, `audio` (code only; public is fine).
- **Kotlin frame-log writer**: attn's `android/tracker-lib/`, consumed by
  nixconf through the attn flake input, as attn §5.12 already decided for
  the tracker. The diary uses the same library; it is not reimplemented
  in nixconf. Until that input exists, the Diary module builds without
  upload (D0 can start with capture and local cache).
- **Opus frames**: attn's `spec/` knows `ndjson` and `pcm_s16le` frames;
  the diary adds an `opus` frame kind (Ogg-less Opus packets with
  `{sample_rate, channels, frame_ms}`), with golden vectors, as a change
  to attn's spec (my call). Whether attn's own check-in audio moves to it
  is attn's decision.
- **diary-brain**: a new package in the private `attn` repo
  (`~/work/personal/attn/packages/diary-brain`), reusing `model`'s
  frame-log format, the `Sealer`/`Signer`/`Sink` services and the
  brain's pull/verify code once it exists. Separate process, system user
  (`diary-brain`), database, DuckDB key, S3 prefix and recipients from
  attn's brain: the diary is more sensitive, and a compromise of one
  should not open the other.
- **NixOS module** for diary-brain on peacelily, from the attn flake, as
  attn-brain is.

### 5.3 Data model

All records are events in the attn frame-log format (attn §5.2): ULID
ids, UTC timestamps plus IANA zone, independent age frames, signed
segments. Buckets (names my call):

- `diary.entry` `{id, recorded_at, about: {date | range | null},
  kind: spoken | read-from-paper | imported-audio | imported-text | typed
  | review, source_app?, original_file_date?, language_hint?}`.
  `about` defaults to `recorded_at`; backfill and "tell this one" set it
  (§5.8, §5.9). The weekly review is an entry of `kind: review` with
  `about` = the week.
- `diary.audio`: the entry's audio, **Opus ~32 kbps mono in the frame
  log** (my call: ~0.2 GB/year at 20 min/day versus ~14 GB as PCM, and
  speech Opus at this rate does not hurt recognition; the lab already
  keeps Opus). Recording writes frames as it goes, so a crash loses
  seconds, not the entry.
- `diary.mood` `{entry_id, scale: 1..5 | null, words: [..], source:
  user | model, model_id?}`. User records always win; model guesses are
  kept separately and never overwrite.
- `diary.photo` `{entry_id | event_id, immich_asset_id, taken_at,
  thumb: bytes (small JPEG, encrypted with the rest)}`.
- `diary.event` `{id, title, about, place?, people: [..], entry_ids,
  photo_ids, immich_album_id?}`.
- `diary.mention` `{entry_id, sentence_id?, kind: place | person |
  event | theme, name, want_to_return?: bool, source: user | model,
  confirmed: bool}`.
- `diary.link` `{entry_id, sentence_ids, target: knowledge-item ref,
  sent_text}` (§5.10).
- `diary.correction` `{entry_id, sentence_id, text, at}`.
- `diary.transcript` (brain-side, derived, rebuildable): per sentence
  `{entry_id, sentence_id, start_ms, end_ms, text, language,
  confidence, model_id, run_id}`.
- `diary.tombstone` `{entry_id}`: hide (§5.16).

Raw (everything the phone wrote) is the only truth; transcripts,
embeddings, model mood, mentions, themes and summaries are derived
layers the brain can rebuild.

### 5.4 Pollen: recording

- **Entry points**: Quick Settings tile, home-screen widget,
  lock-screen-accessible activity, notification action from a nudge, and
  a record button on the Diary home. One tap starts recording.
- **Foreground service** keeps recording with the screen off (as the
  keyboard's `KeepOnService`). Stop by tapping the notification, the
  tile, or the earbud button if available.
- **Audio route**: the connected earbuds' mic when present (Bluetooth
  SCO; verify sample rate on the user's earbuds), else the phone mic.
- After stopping: an optional **mood tap** (1–5 and a few words: calm,
  heavy, restless, light, …; the word list is data, editable) and an
  optional "about when?" (defaults to now). Both skippable; the entry is
  already saved.
- **Live text** while recording is optional and English-only (Parakeet);
  the transcript of record is always the brain's.
- Typed entries: a text field on the same screen (non-goal to polish).

### 5.5 Pollen: reading and listening

Home (text sketch, proposal accepted in conversation without objection):

```
 Diary                                   ● record
 ───────────────────────────────────────────────
 ▸ This week   Mon ▂ Tue ▅ Wed ▃ Thu ▆ Fri ·      (your taps solid, guesses faint)
   4 entries · Sunday: weekly review due
 ▸ A year ago today
   "…walked back from Zamalek, the light on the river…"   ▶ 0:42   🖼 3
 ▸ Places to go back to (5)   ▸ Events (12)   ▸ Themes
 ───────────────────────────────────────────────
 🔎 Search or ask: "what did I say about work in March?"
```

- **Entry screen**: dates, kind, mood, photos, then the transcript as
  sentences; playing highlights the current sentence; tapping a sentence
  plays from there. Mixed Arabic/English text renders with content-based
  direction per sentence (the keyboard audit's N12 lesson). Pending
  transcription shows "waiting for peacelily" with the audio playable.
- **Timeline**: by `about` date, newest first, filterable by kind, mood,
  mention.
- **Offline**: entries recorded on the phone and the last N weeks
  (builder picks N within storage limits) are readable offline from the
  local cache; older ones stream from the brain.

### 5.6 Weekly review (decided: C)

1. A weekly nudge on a day the user picks (§5.11) opens the Review screen.
2. **Tell first**: one prompt ("How was your week?") and a record button.
   Nothing about the week is shown before the user speaks.
3. **Then look**: the screen shows the week's mood line (taps solid,
   guesses faint), what came up more than once (mentions, themes, with the
   entries behind them), places and events of the week, and what the
   telling did not mention but the entries did. Every item links to the
   sentence it came from.
4. **Add**: a second recording, appended to the same review entry.
5. **Confirm** (my call, light): model-suggested mentions from the week
   (places, people, events, "want to go back") are shown as chips to keep
   or drop. This is the one place suggestions get confirmed, so the rest
   of the week has no chores.

The review is never generated in advance and never written by a model.

### 5.7 Mood (decided: C)

The strip and week line use the user's tap when present; otherwise the
brain's guess from the transcript (a small open model, `source: model`),
drawn fainter and labelled as a guess. Guesses are re-run when models
improve; user taps are never touched.

### 5.8 Looking back

- **Search**: full-text over transcripts in both languages (Arabic
  normalisation: hamza/alef/ya/ta-marbuta folding, diacritics stripped;
  my call) plus semantic search on multilingual embeddings
  (EmbeddingGemma on peacelily, as attn). Filters: date range, place,
  person, kind, mood. A result opens the entry at the sentence.
- **Ask**: a question in plain words; the brain retrieves sentences and
  answers with an open model (attn's choices: gpt-oss-20b / Qwen3.5 on
  llama-swap). **Every claim cites entries; an answer without sources is
  not shown** (anti-goal: no unsourced summaries). Each citation plays.
  Ask history is stored encrypted with the diary.
- **Themes**: recurring subjects found by clustering embeddings over
  months, shown with the entries behind them; names are suggested and
  editable by the user.
- **Resurfacing (decided: show everything)**: "a year ago today" (and 2,
  3… years), plus old entries tied to photos the user opens via "tell
  this one". No filtering by mood.
- **Places to go back to**: mentions with `want_to_return`, from the
  user's words or the review chips.

### 5.9 Photos and events (decided: both ways, albums)

- **From an entry**: "add photos" suggests Immich assets taken on the
  entry's `about` date, ranked by GPS near any confirmed place; the user
  picks. Nothing attaches unasked.
- **From a photo ("tell this one")**: opened via Android share from
  Immich or Gallery to Pollen, or a photo picker inside the Diary. Starts
  a recording with the photo attached and `about` = the photo's date.
- **Storage (my call)**: an Immich asset id plus a small encrypted
  thumbnail inside the diary, so entries show their pictures offline;
  Immich keeps originals. Immich access is read-only via an API key
  scoped to read assets, held by diary-brain (sops) and fetched by Pollen
  through the brain, not stored on the phone.
- **Events** are the diary's own albums: title, `about`, place, people,
  photos, entries, all inside the encrypted diary. **Mirroring an event
  to an Immich album is opt-in per event, with a neutral name** (my
  call), because Immich stores album names in plaintext. Mirroring needs a
  write-scoped key, so it is a later milestone.
- Immich moves from butternut to peacelily (`2026-11-22-photos-immich-
  design.md`); asset ids survive a database restore, so pointers survive
  the move. Verify in the move runbook.

### 5.10 Links to the knowledge system (decided: one way plus send)

The user selects one or more sentences and taps **Send**. Only those
words (editable before sending) go to the knowledge system's capture as a
new item (a question, a note) with no reference back. The entry records a
`diary.link` and shows "→ question: bees". The knowledge system never
receives the entry, its mood, date or that it came from the diary. The
capture endpoint is whatever §B defines; until then, Send copies to the
clipboard (my call).

### 5.11 Nudges (decided: welcome)

- Daily, at a time the user sets (default evening), one notification with
  a Record action. Weekly, on a day the user sets, for the review.
- Scheduled **locally** in Pollen (AlarmManager/WorkManager), so they
  work offline and without the brain (my call). Snooze and skip are one
  tap; no streaks, no "you missed" messages.
- The text never contains entry content.

### 5.12 Backfill and import (decided as a phase)

- A **Backfill** screen: photograph a page (one or more photos), then read
  it aloud; the entry is `kind: read-from-paper` with `about` set by the
  user (date, month or year range), and the page photos are attached as
  diary-owned images (encrypted, not in Immich; my call, since a page of
  diary is diary content).
- **Import**: Android share of audio files (voice memos, WhatsApp voice
  notes) and text (notes app) to Pollen → `imported-audio` or
  `imported-text` entries, `about` from the file's date when present,
  confirmable. Reuses the share path from audit idea 7.
- Imported items are diary entries like any other; the original file on
  the phone is left untouched.

### 5.13 Transcription and re-transcription

- diary-brain runs multilingual Whisper (large-v3-turbo first, as attn)
  with word timestamps, segmented into sentences; language per sentence.
- Every transcript row carries `model_id` and `run_id`. A new model is a
  new run over all audio (or a chosen range); the user compares and
  switches the active run. Old runs are kept until dropped.
- **Corrections** (`diary.correction`) are the user's edits to a sentence;
  a re-run never overwrites a corrected sentence. Where sentence
  boundaries move, the correction is re-attached by time overlap, and
  shown for review if it no longer fits (as attn's corrections).
- Read-from-paper entries are transcripts of reading; they stay marked as
  written words read aloud.

### 5.14 Brain API and auth

- HttpApi on 127.0.0.1, published with `tailscale serve` on peacelily.
  Routes (names for the builder): timeline, entry, audio range, search,
  ask, review-context(week), themes, mentions, photos-suggest, upload
  status.
- Auth (my call): Pollen's enrolled device key (Keystore P-256, as attn
  enrolment) signs each request; the brain checks the device registry.
  The Diary module in Pollen sits behind biometric unlock (Android
  `BiometricPrompt`), and the local-cache key is Keystore-bound to it.
- Nothing answers on Tailscale identity alone (attn V B2).

### 5.15 Keys

- Upload recipients: the **diary-brain identity** and the **offline vault
  key** (KeePassXC). The archive survives losing peacelily.
- The diary-brain identity is a **random age identity generated now by
  the owner, kept in the vault**, not derived from a host key (my call:
  one host key yields one age identity, so a derived key could not be
  separate from attn-brain's, and peacelily is not up). The phone needs
  only its public half, so **D0 uploads real entries** before any brain
  exists. At D1 it is installed on peacelily as a sops secret encrypted
  to peacelily's host key and the vault, owned by `diary-brain`; that
  needs attn's P0 (primary key off agent hosts) done first.
- **Enrolment** before any brain exists: a `diary device enrol` command
  in the attn repo, run by the owner, creates the prefix-scoped IAM user
  through the Alchemy stack and writes the device record (`device_id`,
  signing public key, IAM user) as a signed event under `diary/registry/`;
  diary-brain reads its registry from there at D1 (my call). Own registry,
  not attn-brain's.
- Unlike attn's phone, Pollen must read recent entries back: a separate
  **local-cache key** (AES-GCM in Android Keystore, user-auth bound)
  encrypts the cache. The upload copy stays encrypted to the recipients
  only.
- S3: `diary/<device_id>/…` prefix, PUT-only per device, versioning +
  Object Lock, nobody's everyday role deletes (attn §6).
- Rekey and stolen-device handling as attn §6.

### 5.16 Hiding and purging (decided)

- **Hide** (everyday, from the phone): a `diary.tombstone`; the entry
  disappears from every screen, search, Ask, themes and resurfacing; the
  brain drops its derived rows. An "unhide" list stays reachable in
  settings.
- **Purge** (rare): a separate AWS role with `BypassGovernanceRetention`
  and `DeleteObject` (all versions) on `diary/*` only, assumable only
  with credentials kept in the vault (never on an agent host, never on
  the phone). A `diary purge <entry_id>` command run by the owner
  deletes every object version holding that entry, then tells the brain
  to rebuild. Object Lock is in **governance** mode for `diary/` so this
  is possible; the everyday device and brain roles still cannot delete.
- Consequence for the format (D0): **one entry per segment** (an entry's
  audio and records are sealed into their own segments, never mixed
  with another entry's), so purging one entry never destroys others.
  Later edits (mood, corrections, links) about a purged entry live in
  small segments of their own and are purged with it (the brain's index
  maps entry → object keys).
- The vault copy is only a key, not a copy of the data, so purged
  objects are gone everywhere.

### 5.17 Evening moment shared with attn (decided)

One daily nudge (§5.11) opens one Evening screen in Pollen: attn's chips
(place, energy −2..2, day shape) and the diary's record button with the
mood tap. Chips go to attn's frame log; audio and mood go only to the
diary. attn's design changes accordingly: no `checkin.audio` /
`checkin.transcript`, no spoken check-in prompts; its M1 builds the chips
on this screen. The nudge is owned by Pollen and shown once. The weekly
reviews stay separate (attn's Thursday work review; the diary's on the
user's day).

## 6. Milestones

**D0, capture that never loses anything** (no peacelily needed; real
entries upload from the start, §5.15):
Kotlin frame-log writer passing attn's `spec/` vectors (shared with attn's
Pollen M1); Diary module with record (tile, widget, foreground service),
mood tap, local cache, local playback, nudges; S3 prefix and device
enrolment; upload queue. Value from day one: one place for every new
entry.

**D1, transcripts and listening**: diary-brain pull/verify/decrypt,
Whisper, sentence-timed transcripts; Entry screen with follow-along
playback; timeline. Needs peacelily.

**D2, the weekly review and mood**: Review screen (tell, look, add,
confirm chips); model mood guesses; mentions (places, people, events).

**D3, looking back**: search, Ask with citations, "a year ago today",
themes, places to go back to.

**D4, photos and events**: Immich suggestions, "tell this one" from
share, events; later the opt-in Immich album mirror.

**D5, backfill and import**: Backfill screen, audio/text import; can move
earlier if the user wants to start backfilling during D0 (it only needs
capture).

**D6, re-transcription and corrections**: runs, compare, switch,
corrections.

## 7. Left to the builder

DuckDB layout; sentence segmentation; FTS and embedding index details;
local cache size; the exact Opus settings within "speech, ~32 kbps";
screen layout beyond the sketch; API route shapes; prompt wording for
Ask, mood guesses and mentions (expect iteration on real use, which only
the user and the open models see); the mood word list's defaults.

## 8. Seams for later

- **Attention tracker**: shares the evening screen (§5.17). Its location
  data could suggest places for entries; not in v1.
- **Knowledge system**: the Send capture endpoint (§5.10).
- **Dictation lab**: diary audio as training data only by per-entry
  opt-in, later.
- **Desktop reading**: a PWA on diary-brain, attn's passkey pattern.

## 9. Risks

1. Egyptian Arabic transcripts are poor at first → audio is the record,
   playback is first-class, re-transcription is designed in.
2. peacelily not up → D0 is useful without it; the queue holds entries.
3. The habit lapses → one-tap capture, welcome nudges, no guilt.
4. Ask hallucinates → citations required, answers without sources hidden.
5. Bluetooth mic quality varies → verify on the user's earbuds in D0.
6. Two frame-log writers drift → attn's `spec/` vectors in both CIs.
7. Immich ids change on migration → check in the move runbook.

## 10. Open

Nothing blocking. Builder-check questions and their answers: deletion
(§5.16, user), keys and enrolment before peacelily (§5.15, my call),
the attn check-in overlap (§5.17, user), where the Kotlin writer lives
and Opus frames (§5.2, my call).
