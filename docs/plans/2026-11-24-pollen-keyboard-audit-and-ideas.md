# Pollen keyboard: UX audit round 2, feature ideas, training-lab scoping

2026-11-24. Read-only review of `apps/phone/` at `84b357e` (main after the
keep-on, no-mic and no-speech work), plus the desktop side
(`modules/nixos/features/dictation*.nix`, `dictation/dictate-stream.py`).
**From the code only**: nothing was built or run (butternut was on battery),
so anything about on-device behaviour is marked *verify*. Paths are relative
to `apps/phone/app/src/main/java/nixconf/phone/` unless they start with
`modules/`, `res/` or `docs/`.

Three parts: (1) what the 2026-11-23 audit left open, plus new findings;
(2) what else the keyboard could do, ranked; (3) the "personal training
lab": what data exists, what is missing, three architectures and a pick.

A parallel thread is adding an **Auto / Phone** engine toggle to the top
row. It is not repeated here; §1.4 says how it fits.

## 1. UX audit, round 2

### 1.1 Status of the first audit's findings

Done since (all confirmed in the current code): F1, F2, F3 (fixed 260 dp
height), F4, F5 (⌫ and enter only), F6, F7, F9, F10, F11, F21, F22, F23,
F25, F26, F29, F33, and the copy table. Also new since the audit, and good:
the no-speech watchdog (`session/DictationSession.kt:227-253`), Keep on
(`ime/KeepOnService.kt`), the Pollen name and icon.

Still open, with where they stand today:

| # | Sev | State now | Where |
|---|---|---|---|
| F8 | **high** (was med) | Cancel is offered while *Finishing* too, and `cancel()` marks the draft CANCELLED even when segments already have text. Worse now than at the first audit: with segments, a 3-minute prompt whose last segment hangs loses everything already heard. | `ime/Panel.kt:143`, `session/DictationSession.kt:301-314` |
| F12 | med | "Nothing heard" drafts are hidden from the panel and skipped by auto-retry but stay PENDING forever in the app. (The new NO_SPEECH path does it right: CANCELLED, audio kept.) | `ime/Panel.kt:118`, `AppServices.kt:171-181`, `session/DictationSession.kt:447` |
| F13 | med | Mic still at the left edge; status to its right. | `ime/Panel.kt:168-171` |
| F14, F15 | med | Setup is still static buttons (now plus "Allow notifications"); the mic tap without permission still jumps to the app with no words. | `ui/MainActivity.kt:119-139`, `ime/DictationIme.kt:216-218` |
| F16, F17 | med | Fetch errors swallowed; `onOpen(force)` still returns the running job. | `ui/MainActivity.kt:153-162`, `AppServices.kt:114-115` |
| F18, F19, F20 | med | Drafts still last; four buttons in a Row; Retry still copies as a side effect; Discard has no undo. | `ui/MainActivity.kt:97-103`, `:269-282`, `:274`, `:301-310` |
| F24 | low | Text glyphs ⌨ ● ■ ⌫. | `ime/Panel.kt:136,230,424` |
| F27 | low | Stock Material You; level meter in `primary`, mic in `error`: two live colours. | `ui/Theme.kt`, `ime/Panel.kt:279` |
| F28 | low | Title padding, empty-Text spacer, `Theme.Material.NoActionBar` (dark flash in light mode, *verify*). | `ui/MainActivity.kt:97,103`, `AndroidManifest.xml:19` |
| F30 | med | Language lives in the service, lost when it is destroyed; not shown while recording; "EN" read as a word. | `ime/DictationIme.kt:69`, `ime/PanelText.kt:357`, `ime/Panel.kt:139` |
| F31, F32 | low | "Parakeet ready (English, offline)" hardcoded; no download cancel; update flow unchanged. | `ui/MainActivity.kt:191`, `:227-233` |
| F34 | low | `isAuxiliary` still unset. | `res/xml/method.xml` |
| Undo after delivery | **high** | Not implemented: see N1. | |
| Fewer taps per burst | med | No auto-start, no auto-return setting. | |

### 1.2 New findings

Ranked by how much they would bother someone dictating all day, mostly
long agent prompts in English and Arabic. Severity as before: **high** loses
text or is a dead end in the core flow; **med** friction on every use; low
polish.

**N1 · high · No way back from a bad transcription.** `Done` shows the text
and nothing else (`ime/Panel.kt:245`). A mis-heard 300-character prompt has
to be removed by holding ⌫ (repeat at 50 ms per character,
`ime/Panel.kt:411-415`: about 15 s) or by switching keyboards and
selecting. What the user sees: a wall of wrong text and a delete key.
Fix: the IME keeps the last committed string; `Done` shows **Undo** and
**Copy** for ~10 s. Undo reads `getTextBeforeCursor(len + 1)` and calls
`deleteSurroundingText(len + 1, 0)` only if it still matches (same rule the
first audit gave). Copy covers the case where the host app ate the text.

**N2 · high · Words run together when the field already ends in a word.**
`commit("$text ")` appends a space after but never checks what is *before*
the cursor (`session/DictationSession.kt:354,391`). Burst, ⌫ one wrong
character, burst again: "deploy butternutthen run". Same after text typed
with the other keyboard. What the user sees: glued words, fixed by hand
each time. Fix: before commit, `getTextBeforeCursor(1, 0)`; if it is not
whitespace and the new text does not start with a `NO_SPACE_BEFORE`
character, prepend a space. That is the desktop's `joined()` rule
(`segment/Texts.kt:154`) applied at the field boundary. Also skip the
trailing space when the next character after the cursor is already a
space (`getTextAfterCursor(1, 0)`).

**N3 · high · The no-speech watchdog stops the session while the user is
still thinking.** `NO_SPEECH_SEC = 10` (`session/DictationSession.kt:570`,
profile `noSpeechSec`): tap the mic, look at the agent's last reply, start
composing, and at 10 s the panel says "Stopped: no speech heard. Mic muted
or in use by another app?" (`ime/PanelText.kt:442`). On the desktop this
rule is right because the key is pressed when speech starts. On the phone
the mic is tapped first and the thinking happens after. For agent prompts
this will fire daily. Fix: phone default 20 s (the profile already has a
separate `phone.noSpeechSec`), and before stopping, a visible countdown
in the status for the last 5 s ("Nothing heard yet · stops in 4"), so a
breath restarts it. Keep the message honest when it does fire: "Nothing
heard in 20 s: stopped" with the mic ready for a tap.

**N4 · high · Cancel while finishing throws away transcribed segments
(F8, worse now).** `ime/Panel.kt:143` shows *Cancel* for both Recording
and Finishing; `cancel()` saves CANCELLED whatever `segments.jsonl` holds.
Fix: while Finishing the button reads **Stop waiting**: cancel the in-flight
transcription, save the draft PENDING with `joinTexts(texts)` so far, state
`Kept(draft, "stopped waiting")` with **Insert here**. While Recording,
*Cancel* keeps a 5 s **Undo** chip (set the draft back to PENDING; the
audio is still there).

**N5 · med · Dictating into a selection already works, but nobody knows.**
`commitText` replaces the current selection, so select a wrong word, tap
the mic, say the right one: done. The panel says nothing, and the trailing
space (N2) is still appended, so "word " replaces "word". Fix: override
`onUpdateSelection`; when `selEnd > selStart`, the status reads "Replaces
the selected text" and the commit adds no spaces. This is the cheapest
"fix one word" path there is: no keyboard switch.

**N6 · med · Auto-retry of pending drafts competes with the live session.**
Every keyboard open runs `retryPending` (`AppServices.kt:126,171-181`),
which transcribes every text-less draft in series on the same
whisper-server. The user opens the keyboard to dictate *now*; the live
segments queue behind a 5-minute draft from yesterday. Fix: retry only when
the session is Idle, cancel the retry job in `start()`, and prefer the app
screen (or Wi-Fi + charging) for retries of drafts longer than, say, 30 s.

**N7 · med · No structure in long prompts.** Agent prompts have
paragraphs and bullets. Batch mode types everything at stop; enter is off
while active (`ime/Panel.kt:158`), rightly, so there is no way to put a
paragraph break in a prompt without the other keyboard afterwards. Fix:
spoken commands in post-processing (§2, idea 1): "new paragraph", "new
line", "bullet", and the Arabic equivalents, turned into `\n\n`, `\n`,
`\n- ` in `clean()` (`segment/Texts.kt`), shared with the desktop.

**N8 · med · Deleting the last word is 20 taps or a hold.** ⌫ sends
`KEYCODE_DEL` per press (`ime/DictationIme.kt:137`). Transcription errors
are word-sized, not character-sized. Fix: a **⌫ word** key next to ⌫:
`getTextBeforeCursor(64, 0)`, find the previous word boundary,
`deleteSurroundingText(n, 0)`. With N5 that covers most one-word fixes
without leaving the panel. (Keep key events for ⌫: with a selection they
delete it, and WebViews honour them.)

**N9 · med · Keep on + another keyboard ends in a draft, every time.**
The *⌨ Keyboard* button is enabled while a background recording runs
(`ime/Panel.kt:131`), which is the point of Keep on. But once Gboard is
active, our `onFinishInput` dropped the token, so `finish()` always
takes the FIELD_CHANGED branch (`session/DictationSession.kt:391-398`) and
the text waits as a draft until Pollen is reopened in that field: three
more taps. Fix: when a background session ends with text and the IME is
not current, copy the text to the clipboard and say so in the Stop
notification ("Copied · paste it where you are"), so the other keyboard
finishes the job with one long-press. (Android 13+ shows a clipboard toast;
fine, the user asked for it.)

**N10 · med · Language is invisible and forgetful (F30, sharpened).**
With EN and AR in daily use, the status line while recording
("0:12 · butternut", `ime/PanelText.kt:357`) never says which language the
session is in, and the choice resets when the service dies. Fix: show the
language in Recording and Finishing text ("0:12 · butternut · AR"); persist
the last choice in prefs; remember it **per app package**
(`attribute.packageName` is at hand in `onStartInput`): WhatsApp in Arabic,
T3 in English, without a tap.

**N11 · med · A forgotten Keep on has no ceiling.** The desktop stops at
`maxSeconds` (1800 s); the phone has no limit, and the foreground service
keeps the mic open until the battery dies or the user remembers. Fix: a
`maxSeconds` in the profile (same default), a warning colour on the timer
past `longSessionMinutes` as on the desktop, and the notification shows the
running time.

**N12 · med · Arabic text in the panel.** `Done`, `Kept` and draft rows
render Arabic in LTR-aligned `Text`s with an ellipsis at line 2
(`ime/Panel.kt:249-257,303-310,342-351`). Mixed Arabic/Latin prompts
("ابني flake جديد") depend on Compose's bidi defaults for alignment.
*Verify on device*; the safe fix is `textDirection = TextDirection.Content`
and `textAlign = TextAlign.Start` on those styles. `NO_SPACE_BEFORE`
already has the Arabic marks, good.

**N13 · low · The drafts list stays open after an insert.** `showDrafts` is
a `remember` (`ime/Panel.kt:112`): after inserting one of three drafts, the
panel comes back to the list, not the mic. Fix: set it false in `insert`
and `retry` callbacks, and whenever `state` becomes Recording.

**N14 · low · Stream mode has no indicator and no per-phone switch.** The
profile sets `mode` fleet-wide; composing text misbehaves per app, so the
user will want it off in one app and on in another. Fix: "STREAM" next to
the language in the status while recording; a per-app override in prefs
(same map as N10).

**N15 · low · "Delivered" is final.** Once typed, a draft leaves every list
(`AppServices.kt`, `pending` only; `ui/MainActivity.kt:249-253`). If the
host app lost the text (a WebView reload, a chat that cleared its box),
the audio is still on disk for `keepDays` but unreachable. Fix: a
"Recent" section in the app (last 20 delivered, text + Copy). This is also
the first brick of §3.

### 1.3 What already works and should stay

The latch mic and fixed-height panel; the Finishing ring with counts;
Insert here / Copy on a kept draft; the password/number/incognito rules;
the no-speech watchdog's *intent* (just not its 10 s on the phone); Keep
on as a toggle under the meter, not a separate mode; haptics only at
start, stop and result; the live region without the timer.

### 1.4 How the Auto / Phone toggle fits the top row

The top row (`ime/Panel.kt:125-148`, 48 dp) holds *⌨ Keyboard*, the
language, a spacer, then *Cancel* or the drafts chip. Observations for the
parallel thread:

- **Put it where the language is, in the same style**: a two-state
  `TextButton` ("Auto" / "Phone"), disabled while active, exactly like the
  language. The row then reads: ⌨ Keyboard · EN · Auto ……… 2 drafts. On a
  360 dp window that is about 110 + 48 + 64 + 90 dp plus padding: it fits,
  but only just. Turning *⌨ Keyboard* into an icon-only 48 dp button (F24)
  buys the room back and should go in the same change.
- **The status line already tells the outcome** (`engineLabel`: "on phone"
  vs "butternut"), so the toggle needs no extra feedback beyond its label.
  While recording, the toggle's state should stay visible (disabled, not
  hidden): the user wants to see why it says "on phone".
- **Phone + Arabic is a dead end**: Parakeet is English only
  (`localEligible`, `session/DictationSession.kt:532`). If the engine is
  forced to Phone and the language is AR, the mic tap must say so
  ("On-phone is English only: switch to Auto or EN") rather than record
  into a NO_SERVER draft. Either disable the Phone state while AR is
  selected or flip the language with a notice.
- **"Auto avoids a server on battery"** needs a signal: the server's
  `GET /` readiness probe does not say "on battery". Cheapest: the profile
  server publishes `status.json` next to `profile.json` (the design doc's
  "fleet status" idea) with `{onBattery, since}`, and `chooseEngine` reads
  it with the probe. Keep the per-app memory (N10) in mind: the same
  prefs map can hold the engine choice too.

## 2. Feature exploration

What the keyboard could do next, ranked by value over effort for someone
who dictates T3 Code and Claude Code prompts from the phone in English and
Arabic. Each has a one-line sketch of where it lands in the code.

| # | Idea | Value | Effort | Sketch |
|---|---|---|---|---|
| 1 | **Spoken formatting commands** ("new paragraph", "new line", "bullet", "code block", and Arabic forms: "سطر جديد", "فقرة جديدة") | high | low | A phrase table in `segment/Texts.kt` applied in `clean()`, JVM-tested; the table ships in the profile (`commands`) from a new `modules/dictation-commands.nix`, and `dictate-stream.py`'s `clean()` reads the same table from its config, so both sides format alike. |
| 2 | **Personal replacement rules** ("nix conf" → nixconf, "tee three" → T3, "cloud code" → Claude Code, Arabic transliterations of host names) | high | low | `Profile.replacements: List<Pair>` applied after `clean()`; a public technical list in Nix plus a *private* file merged at serve time (§3.5). The same rules go into the desktop config. Fed by the training lab. |
| 3 | **Undo, Copy and ⌫ word** (N1, N8) | high | low | `lastCommitted` in `DictationIme`; `Done` gains two buttons; a word-delete key in `KeyRow`. |
| 4 | **Arabic → English translate toggle** for prompts to agents | high | low | whisper.cpp's server takes `translate=true` (*verify the field name on the pinned build*); a third state on the language button ("AR→EN") or a long-press; `WhisperClient.transcribe` adds the form field; server only (Parakeet cannot). |
| 5 | **Live tail while recording (batch mode)** | med | low | `Recording.liveTail` from `cur.text` (the last segment's text, ellipsised from the start) in the status slot, as the first audit sketched. Confidence while speaking a long prompt without looking at the field. |
| 6 | **Per-app memory** of language, engine and stream mode (N10, N14) | med | low | A prefs map keyed by `packageName`; read in `onStartInput`, written when the user toggles. |
| 7 | **Share audio to Pollen** (WhatsApp voice notes, recorder apps) and **dictate to clipboard** (Quick Settings tile / launcher shortcut, no field needed) | med | low–med | An `ACTION_SEND` audio activity that creates a draft from the file (`DraftStore.create` + convert to 16 kHz WAV) and runs `session.retry`; the tile starts `KeepOnService` with a "copy when done" flag (the N9 path). |
| 8 | **Tidy with a local model** ("Tidy" in `Done`: fix obvious mis-hearings, add paragraphs, keep the wording) | high | med | A `llmUrl` in the profile pointing at llama-swap (peacelily; open-weight only, per the user's rule); `Undo` + commit of the result; show a diff-ish preview in the status slot before committing. Needs peacelily redeployed, or a small model on butternut's RTX 3050. |
| 9 | **Inbox to the agents** (dictate a task while out; it lands where a T3 thread or `dictate inbox` picks it up) | high | med | Phone writes `inbox/<id>.md` (text + language + time) through the same upload path as §3.4; on butternut a `dictation-inbox` dir the user (or a scheduled agent) reads. Syncthing is the alternative transport, but Android's scoped storage makes app-private files awkward to sync. |
| 10 | **Auto-start when opened by a voice key, auto-return after typing** | med | low | Two settings; `onStartInputView(!restarting && autoStart && kind == TEXT)` calls `onMic()`; `switchQueued` defaults to the setting. Off by default: opening from the picker would otherwise start recording. |
| 11 | **Headset button starts and stops** (the user's Sony headset shows in desktop drafts as the mic) | med | med | A `MediaSession` held while the panel is visible or Keep on runs; `KEYCODE_HEADSETHOOK` / `MEDIA_PLAY_PAUSE` toggles the session. Hands-free dictation while walking. |
| 12 | **Recent (delivered) drafts** in the app, searchable | med | low | `DraftStore.recent()` over DELIVERED; a list with Copy and Share. Prerequisite for §3. |
| 13 | **Push-to-talk** as an option (hold the mic) | low | low | `pointerInput` on the mic like `DeleteKey`'s: down starts, up after `tapMs` stops; tap still latches. |
| 14 | **Parakeet hotwords** for the on-phone engine | med | unknown | sherpa-onnx hotword biasing needs modified beam search on a transducer; whether the TDT model supports it on the Android AAR is the open question from the design doc. Spike first. |
| 15 | **Auto language** as a third toggle state | low | low | `language = "auto"` is already used for lost-meta drafts; server only; detection on 1-second segments is unreliable, so pair with per-app memory. |

Ideas 1–3 together are a week of small, testable changes and remove most
of the daily friction. Ideas 8 and 9 are the ones that change what the
phone is *for*: capturing agent work away from the desk.

## 3. The personal training lab, scoped

The idea, in the user's words: take every dictation draft (phone and
desktop), have Claude find likely transcription errors and typos, surface
them as a correction game in an app, and feed the corrections back as a
personal dictionary (Whisper prompt), find-and-replace rules, and
eventually fine-tuning.

### 3.1 What data exists today

**Phone** (`files/drafts/<id>/`, `drafts/DraftStore.kt`):

| File | Content |
|---|---|
| `audio.wav` | 16 kHz mono 16-bit, whole recording (about 1.9 MB/min, uncompressed) |
| `meta.json` | `status` (pending/delivered/cancelled), `createdMs`, `updatedMs`, `language`, `engine` (server URL or "local"), `text` (cleaned transcript), `error` |
| `segments.jsonl` | per segment: `i`, `start`, `end` (sample offsets into the WAV), `text`, `engine` |

Delivered and cancelled drafts are deleted after `keepDays` (7). There is
no text history beyond that. Incognito deliveries are deleted at once.

**Desktop** (`~/.local/state/dictation/`, on normal persistent disk on hazel
and butternut; `dictate-stream.py`):

| File | Content |
|---|---|
| `drafts/<id>/audio.pcm` → `audio.opus` | raw PCM while pending; Opus 24 kb/s once done or cancelled, pruned after 7 days |
| `drafts/<id>/meta.json` | `id`, `sid`, `started`, `lang`, `mode`, `source` (mic/file), `input` (the mic, e.g. the headset), `backend` ("butternut GPU"), `status`, `complete`, `error`, `delivered` (pasted/typed/clipboard), `duration` |
| `drafts/<id>/commits.jsonl` | per segment: `i`, `start`, `end`, `ok`, `text`, `delivered` |
| `drafts/<id>/transcript.txt` | the joined text |
| `YYYY-MM-DD.md` | the **journal**: one line per delivered session, `- HH:MM:SS · sid · text`. Never pruned: this is the long-term text history. |

On butternut right now: 10 drafts, 2 journal days, 7.4 MB. hazel, the
primary device, will hold more (not inspected).

### 3.2 What is missing

- **What the user changed after delivery.** Nothing records it, on either
  side, and nothing can: the text is pasted into arbitrary windows and
  fields, and edits happen in another keyboard or app. One exception is
  worth a lot: **prompts to agents**. T3 Code threads and Claude Code
  sessions (`~/.claude/projects/*/*.jsonl`) keep the user's messages as
  sent. Matching a journal line to the message sent a minute later (same
  text, fuzzy) yields the edit diff for free: the lab's best signal, with
  no new instrumentation.
- **Text history on the phone**: everything is gone after 7 days.
- **Raw model output**: `clean()` strips tags and whitespace only, so the
  stored text is near-raw; but the **prompt used**, the **model/backend
  version**, the **target app and field kind**, and the **mode** are not
  stored on the phone (the desktop has backend and mode).
- **Confidence**: whisper.cpp's server returns only `text` with
  `response_format=json` (`engine/WhisperClient.kt:59`,
  `dictate-stream.py:557`). `verbose_json` adds per-segment
  `avg_logprob`, `no_speech_prob`, `compression_ratio` and per-token
  probabilities (*verify on the pinned build*). Low-probability tokens
  are the cheapest "likely error" detector there is, and they come from
  the same request.
- **The desktop prompt is empty.** `preferences.dictation.prompt` defaults
  to `""` (`modules/nixos/features/dictation.nix:423-425`); the plan's
  step to default it to `self.dictationVocabulary` was deferred
  (`docs/plans/2026-11-22-phone-dictation-keyboard-plan.md:245`) and never
  done. Today the fleet vocabulary reaches only the phone. The laptops'
  dictation would improve before any lab exists by closing that gap.
- **A correction record**: nowhere to store "this span should have been
  that", with a reason (vocabulary / replacement / punctuation / ignore).

### 3.3 Cheap instrumentation first (both sides, no lab yet)

1. Phone: append delivered text to `journal.jsonl` (`{ts, id, language,
   engine, package, mode, text}`) before pruning; keep it. Desktop: add
   `backend` model name and the prompt hash to `meta.json`.
2. Both: request `verbose_json`, store per-segment `avg_logprob`,
   `no_speech_prob` and the token probabilities next to the text
   (`segments.jsonl` / `commits.jsonl`). Nothing changes for the user.
3. Both: `corrections.jsonl` with a stable schema
   `{draft, segment, from, to, kind, ts, source}` where `source` is
   `user` (the game), `agent-diff` (§3.2's T3 matching) or `rule`.
4. Fix the desktop prompt default (§3.2).

### 3.4 Architectures

**A · Desktop lab, browser game.** Drafts flow to butternut. Analysis is a
Python stdlib script in the dictation feature (`dictate-lab analyse`):
heuristics first (low-probability tokens, words outside hunspell en/ar,
near-misses of vocabulary entries by edit distance, repeated patterns),
then an optional pass through a local open-weight model (llama-swap on
peacelily; butternut's RTX 3050 can run a small Qwen for proofreading). It
writes `suspects.jsonl`. The game is a small HTML page served from
butternut on the tailnet: the span, the audio snippet (segment offsets are
known on both sides), accept / fix / ignore. Corrections land in
`corrections.jsonl` on butternut.
Transport from the phone is the sticking point: `files/drafts` is
app-private, so Syncthing-Android cannot read it (scoped storage), and
`darkhttpd` only serves. Needs a tiny upload endpoint.
*Pros*: one copy of everything, audio at hand, no Kotlin beyond an upload,
analysis in the language the repo already uses for dictation. *Cons*: a
browser game on the phone is less pleasant than a native one; butternut
must be on.

**B · On-phone lab in Pollen.** Pollen keeps its journal, calls the LLM
endpoint itself on Wi-Fi, stores suspects locally and shows the game as a
screen: swipe accept / fix with the other keyboard / ignore, play the
segment's audio (the WAV and sample ranges are right there). Corrections
stay on the phone and are exported (upload, or a shared file) for the Nix
side. Desktop drafts would have to travel *to* the phone (served by
butternut: serving transcripts unauthenticated on trusted LANs is a step
beyond serving a profile, so tailnet-only at least).
*Pros*: native, offline-capable game; the phone is where the user is.
*Cons*: two analysis implementations or one that only sees phone data;
the corrections still need a desktop step to become Nix; more Kotlin.

**C · Hybrid: data and analysis on butternut, game in Pollen and in a
page (pick).** Phone uploads finished drafts (text, segments, audio) on
Wi-Fi after delivery to a small inbox endpoint added to the
`dictation-server` feature (Python stdlib `http.server`, 60 lines, bound
to `tailscale0` only, writing to the user's
`~/.local/state/dictation/phone/<id>/`). hazel's `dictate` posts its draft
bundle to the same inbox after a session (it already talks to that host),
so all drafts and the journal sit in one tree on butternut.
`dictate-lab analyse` as in A. The **lab API** is three JSON routes
(`/suspects`, `/audio/<draft>/<segment>`, `POST /correction`) on the same
tiny server; the game is a screen in Pollen that talks to it (OkHttp is
there; a list, an audio player, three buttons) *and* a one-file HTML page
for the desktop, same API. `dictate-lab apply` turns accepted corrections
into: (1) vocabulary candidates, as a proposed diff to
`modules/dictation-vocabulary.nix` the user reviews (public, technical
words only; Whisper's prompt budget is about 224 tokens, so the lab ranks
by correction frequency and suggests rotations out as well as in); (2)
`replacements.json` in the user's state dir, **outside git**, merged into
the served `profile.json` at link time and into the desktop's config at
runtime; (3) a dataset manifest (`audio snippet, corrected text,
language`) for later.
*Pros*: one source of truth, audio on hand, a native game, corrections
flow to Nix with one script, nothing personal in the repo. *Cons*: a new
service with the user's transcripts behind it: tailnet-only binding and
a Tailscale ACL (the tailnet-as-code doc) are the minimum; add a bearer
token in the profile later if the server ever reaches a trusted LAN.

**Pick: C.** A is C without the native game; B scatters the data. C's
inbox endpoint is also what idea 9 (§2) needs, so it pays twice.

### 3.5 Privacy and the public repo

- Transcripts, audio, corrections, replacement rules with names, and the
  journal never enter git. They live under `~/.local/state/dictation/`
  on butternut (and the phone's app storage) and are not in any
  persisted-to-repo path. `replacements.json` is private by construction;
  only the vocabulary *list* is public, and only after the user accepts
  each word.
- Analysis uses open-weight models on the user's hardware only
  (llama-swap on peacelily; ollama on butternut exists but is not started
  at boot). Claude, in the user's sense of "have Claude analyse", can still
  be the *designer* of the heuristics and the reviewer of a redacted
  summary, but the transcripts themselves do not go to a commercial model
  (the user's standing rule for personal data).
- The lab API and inbox bind to `tailscale0` only; the Tailscale ACL
  limits them to the phone and the laptops.

### 3.6 Fine-tuning, honestly

Vocabulary, replacements and a per-app prompt will capture most of the
gain for named entities and recurring phrases, and they work today on
both engines (replacements) or on Whisper (prompt). Fine-tuning Whisper
large-v3-turbo with LoRA on a few hours of personal speech is a
peacelily-sized job (not the RTX 3050) and needs the dataset §3.4 builds;
plan it as phase 4, after the lab has produced a few hundred corrections,
and measure WER on a held-out week before and after. Egyptian Arabic is
where fine-tuning would matter most and where the public models are
weakest, which argues for collecting the Arabic data carefully from day
one (language tag per draft is already there).

### 3.7 Phases

1. Instrumentation (§3.3) and the desktop prompt default. Small PRs, no
   new service.
2. Inbox endpoint in `dictation-server`; phone upload on Wi-Fi after
   delivery; `dictate` upload after a session.
3. `dictate-lab analyse` with heuristics only; `dictate-lab review` as the
   HTML page (fast to build, usable from the phone browser on day one).
4. The LLM pass (peacelily redeployed, or a small model on butternut) and
   the Pollen game screen.
5. `dictate-lab apply`: vocabulary diffs, private replacements merged into
   the profile and the desktop config.
6. Dataset manifest; fine-tuning experiments on peacelily.
