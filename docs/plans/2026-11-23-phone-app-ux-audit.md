# Phone app UX audit (dictation keyboard + app screen)

2026-11-23. Read-only review of `apps/phone/` at `5ec5acb`. **Audited from
the code only**: the app was not run on a device, so layout and system
behaviour (insets, HyperOS IME switcher, TalkBack output) are inferred
from the code and the Android docs, and are marked *verify* where it
matters. Paths below are relative to
`apps/phone/app/src/main/java/nixconf/phone/` unless they start with `res/`
or `AndroidManifest.xml` (both under `apps/phone/app/src/main/`).

## Status

Quick wins done on branch `phone-ux-quickwins` (on top of
`phone-pause-segments`), 2026-11-23. Built and JVM-tested, **not yet run on
a device**. Line numbers in the tables below refer to `5ec5acb` and no
longer match.

| # | Status | What changed |
|---|---|---|
| F1 | done | `SessionState.Transcribing` became `Finishing(engine?, done, total)`, set inside `stop()` before anything is awaited. Engine null shows "Stopped · finding server…", the timer stops and the mic turns into a spinner. With segments still queued it shows "Finishing 2 of 5 · butternut" and a determinate ring (`SegmentFeed.closed` counts the segments cut). A second tap does nothing. |
| F2 | done (queue) | While finishing, *⌨ Keyboard* toggles to "⌨ After typing": the switch happens right after the commit (`Done`). A draft result cancels it, so the user sees what happened. Why queue rather than disable: the switch stays one tap, which suits one-handed bursts, and the switch can no longer cause FIELD_CHANGED. Disabling would make the user wait on the panel for up to 20 s. |
| F3 | done (minimal) | Fixed panel height, 260 dp (at most 55 % of the screen height, for landscape). The mic sits in a fixed slot. The drafts list replaces the main view inside the same height, and messages are capped at 2 lines. The mic is not centred yet (F13). |
| F4 | done | Password variations (text, visible, web, number): mic disabled, status "Password field: switch keyboard to type", no draft offered or listed. Number, phone and date fields: a warning in the status, and stream mode is off. Incognito (`IME_FLAG_NO_PERSONALIZED_LEARNING`) rule: **a draft typed into an incognito field is deleted (audio, text, segments) once delivered**, by the session or from the drafts list. A recording that could *not* be typed stays a PENDING draft as usual (never lose audio), and so does its text until it is delivered or discarded. Stream mode is off in incognito fields. |
| F5 | done | A key row at the bottom: ⌫ (repeats while held) and the editor's enter key (Send/Search/Go/Next/Done/Previous through `performEditorAction`, or ↵ as a newline when the field asks for none). Both are off while a session runs. |
| F6 | done | A Kept draft with text shows the text plus **Insert here** and **Copy**. Without text it shows **Retry**, which transcribes and types it. Draft rows have a visible Copy button (long-press still works). |
| F7 | done | On a new input (`!restarting`), `Done` and a Kept draft without text go back to Idle. A Kept draft with text that is still pending on disk stays offered (Insert here). |
| F9 | done | `transcribe` calls back before the on-phone model runs, so the label says "on phone" from then on, both for the whole file and per segment (for the rest of the session). |
| F10 | done | The previous IME, else the next one, else the system picker (`switchAway`). No long-press yet. |
| F11 | done | Tapping an untranscribed row transcribes it and types it if the user is still in the same field (same input token). The row shows a spinner, and a second tap is ignored. `deliver` refuses while a session runs (`BUSY`). |
| F21 | done | `performHapticFeedback`: LONG_PRESS on start, CLOCK_TICK on stop, CONFIRM when typed, REJECT when saved as a draft. Nothing per segment. Follows the system setting. |
| F22 | done | The status line is a polite live region with short phrases ("Recording", "Stopped, finding server", "Typed: …", "Saved as draft …"), without the timer. |
| F23 | done | The mic has a content description and a state description, and its glyph is excluded from semantics. The level meter is a plain drawn bar, not a progress indicator. |
| F25 | done | Draft rows are at least 48 dp tall. |
| F26 | done | Newest first on the panel, with the age ("5 min ago"). |
| F29 | done | `onEvaluateFullscreenMode() = false`. |
| F33 | done | Start failures are mapped to plain messages ("Microphone in use by another app", "Can't save the recording: storage full?") via `StartException(storage)`. "Already typed or discarded" is separate from "No field to type into". Errors use the error colour. |
| Copy | done | Panel copy as in the table below. In the app: "Waiting for the profile", "Waiting for Wi-Fi · about 650 MB", **Download on mobile data**. Not done: "Save & test" (that is the F16 rework). |
| F8, F12–F20, F24, F27, F28, F30–F32, F34 | open | Out of scope for the quick wins (larger changes, or the app screen). |

## Summary

The core design holds up. Tap to start and tap to stop on a big latch mic,
an engine label, and a "never lose audio" draft model are the right base
for short one-handed bursts, and most failures end in a recoverable draft.
The weak spots sit around the edges of that core flow:

1. **Two traps lose the user's text without any feedback.** After stop, the
   panel can keep looking like it is recording for up to 20 s while the
   server probe finishes. And switching back to the other keyboard while
   transcribing (which the panel allows) turns the result into a draft
   nobody sees.
2. **After the text lands, the panel has no keys for what comes next**:
   no backspace, enter/send or undo. Every burst ends with switching
   keyboards. A burst from Gboard costs about 6 taps. It could be 2–3.
3. **Recovery takes too many steps.** A "field changed" draft has its text
   ready, but inserting it takes a chip tap, a row tap and knowing that
   tapping a row inserts it. Retry in the panel transcribes but doesn't
   insert. "Nothing heard" drafts pile up in the app forever.
4. **The panel changes height between states**, so the mic button moves
   between the start and stop taps. The mic also sits at the left edge.
5. **Password and number fields aren't handled.** The panel offers
   dictation into a password field, and the audio and text are stored in
   drafts.
6. Visually the panel is calm and dense enough. But it is stock Material
   You (wallpaper colours, Roboto, a filled primary mic at rest), not the
   desktop's "one ink on paper" look. Haptics and TalkBack announcements
   are missing.

## Flows as written

**First run** (about 8 taps, and the app never confirms a step is done):
open the app → *Allow microphone* (+ system dialog) → *Enable keyboard* →
toggle in Settings → OK the "this keyboard can collect…" warning → back →
*Switch keyboard* → pick Nixconf. The profile (default URL built in) and
the model (on Wi-Fi) need no taps, if the phone is on the tailnet.

**Per burst from Gboard** (about 6 taps): switch to Nixconf (globe or
nav-bar switcher, then pick: 2) → mic (1) → stop (1) → *⌨ Keyboard* (1)
→ send/enter on Gboard (1). With the fixes below (start when opened by a
voice key, return to the previous keyboard after delivery, an action key on
the panel), it becomes 2–3 taps.

**State feedback** (panel `ime/Panel.kt:143-163`):

| State | Panel shows | Gap |
|---|---|---|
| Idle | "Tap to dictate" | fine |
| Recording, probing | "0:03 · checking…" + level bar | fine while speaking; **after stop it stays like this** (F1) |
| Recording, no server | "0:05 · no server" | doesn't say the recording will become a draft |
| Transcribing | "Transcribing… · butternut", indeterminate bar, mic greyed out | label stays "butternut" when the phone takes over (F9); no elapsed time |
| Done | the text, 2 lines | no undo; **still shown the next time the keyboard opens in another app** (F7) |
| Kept: field changed | "Field changed: kept as draft" | text is ready but there's no "Insert here" (F6) |
| Kept: no server | "No server: kept as draft" | no "retry now"; doesn't say it will retry by itself |
| Kept: nothing heard | "Nothing heard" | the draft disappears from the panel but stays pending in the app forever (F12) |
| Mic busy / error | "Microphone: microphone busy" | doubled word, not styled as an error, no next step |
| No profile | "No profile yet: open Nixconf on the tailnet once" | wrong: the keyboard fetches the profile itself |
| Model download, update available | nothing on the panel | app screen only (acceptable) |

## Findings

Severity: **high** = loses or misplaces text, or is a dead end in the core
flow; **med** = adds friction on every use or makes a state unclear; **low**
= polish.

| # | Sev | Area | Where | Problem | Recommendation |
|---|---|---|---|---|---|
| F1 | high | Core flow | `session/DictationSession.kt:124-129`, `:183-185`; `ime/Panel.kt:120,134-138,146-155` | After stop, `finish()` waits for the engine probe (up to 20 s on a cold or slow server, `engine/WhisperClient.kt:36`) while the state stays `Recording(null)`. The red stop button, the ticking timer and Cancel all stay. A second tap does nothing (`stop()` returns when `job != null`). This hits exactly the short bursts the user dictates most, and the first dictation after butternut has gone idle. | Make the state change at the tap: add `Finishing(engine: Engine?)` (or set `Transcribing` with a nullable engine) before awaiting. Show "Stopped · finding server…" with the timer frozen and the mic as a spinner. |
| F2 | high | Keyboard switch | `ime/Panel.kt:80-83`, `session/DictationSession.kt:196-202`, `ime/DictationIme.kt:115-118` | *⌨ Keyboard* is enabled while transcribing. Switching keyboards ends the input (`tokens.finish()`, token goes to null), so the finished text is kept as a "field changed" draft, even though the field didn't change. The Kept message renders on a panel that is no longer visible. Text silently doesn't arrive. | During Transcribing, turn the button into "Switch when typed": set a flag, and in `Done` call `switchToPreviousInputMethod()` right after the commit. Or disable it as during Recording. Never let the switch itself cause FIELD_CHANGED. |
| F3 | high | Ergonomics | `ime/Panel.kt:76-115` | The panel height depends on state: message and no-profile lines come and go, the pending chip hides while active (`:110`), and the list expands by up to 180 dp. The IME window is anchored at the bottom and its content laid out from the top, so the **mic button moves vertically between start and stop**, and the host app reflows on every state change. | Use a fixed panel height, close to the system keyboard's (about 260–280 dp), so the host doesn't reflow on switch either. Fixed slots: a status line, one message line (ellipsised), and the mic in a fixed position. Show pending drafts as an overlay or replacement view inside the same height, not appended below. |
| F4 | high | Fields | `ime/DictationIme.kt:110-125` | `inputType` is never checked. The keyboard offers dictation into password fields (the audio goes to the server and is stored on disk; the text goes into `meta.json`), and into number, phone and date fields, where a transcript like "five" gets rejected or garbled. `IME_FLAG_NO_PERSONALIZED_LEARNING` (incognito) is ignored. | In `onStartInputView`: for password variations (`TYPE_TEXT_VARIATION_PASSWORD`, `VISIBLE_PASSWORD`, `WEB_PASSWORD`, `TYPE_NUMBER_VARIATION_PASSWORD`), disable the mic and show "Password field: switch keyboard", or switch back automatically. For `TYPE_CLASS_NUMBER`/`PHONE`/`DATETIME`, warn or disable. For incognito, deliver and then delete the draft right away. |
| F5 | high | Core flow | `ime/Panel.kt:68-116` (no keys) | After the text lands, the next step (fix a word, add a newline, send) always needs the other keyboard. The panel has no backspace, enter/action or space, so every burst ends in a keyboard switch. | Add a minimal key row in the thumb zone: ⌫ (with repeat), space, and the editor's action key (`EditorInfo.imeOptions` → Send/Search/Go/Done via `performEditorAction`, newline otherwise). This is still "not a key grid", as the design doc asks. |
| F6 | med | Recovery | `ime/Panel.kt:162`, `:110-112`, `:175-177` | A Kept draft with text (field changed, the most common recoverable case) shows only a status line. Inserting it needs the "1 pending" chip, then the right row, plus knowing that tapping a row inserts it. Copying is a hidden long-press. | In `Kept` with `draft.text != null`: show the text (2 lines) plus **Insert here** and **Copy** buttons in the status slot. Show "Long-press to copy" in the list as a visible secondary action, not hidden. |
| F7 | med | State | `ime/DictationIme.kt:120-125` | `onStartInputView` clears `message` but not `Done`/`Kept`. Opening the keyboard in another app later shows the previous dictation's text ("Done") or an old "Field changed: kept as draft". It's confusing, and it shows earlier text in an unrelated app. | On a new input (not `restarting`), reset `Done` to Idle. Keep `Kept` only while its draft is still pending, and phrase it as an offer ("Draft from 14:02 · Insert here"). |
| F8 | med | Cancel | `session/DictationSession.kt:133-145`; `ime/Panel.kt:88` | Cancel while transcribing marks the draft CANCELLED: the recording vanishes from the pending list with no confirmation or undo. That breaks the "nothing silently disappears" anti-goal for the most likely frustration moment (a slow server). | While recording, Cancel discards, with a 5 s **Undo** chip (the draft is only pruned after `keepDays`, so undo is cheap). While transcribing, offer **Stop waiting** (keep as a draft) instead of discard. |
| F9 | med | Engine label | `session/DictationSession.kt:212-229` | If the server fails at upload and the phone takes over, the state stays `Transcribing(Remote)`, so the panel says "butternut" while Parakeet loads (about 1 GB) and runs for several seconds. | Emit `Transcribing(Engine.Local)` before the local call (pass a callback or move the fallback into `finish`). Optionally show "butternut failed → on phone". |
| F10 | med | Keyboard switch | `ime/DictationIme.kt:99` | The result of `switchToPreviousInputMethod()` is ignored. It returns false when there is no previous keyboard (right after enabling, or after the system reset it), and the button then does nothing: a dead end on a panel that can't type. | If it returns false, try `switchToNextInputMethod(false)`, then fall back to `InputMethodManager.showInputMethodPicker()`. Long-press on the button opens the picker. |
| F11 | med | Recovery | `ime/DictationIme.kt:180-187`; `ime/Panel.kt:176,182` | Retry from the panel transcribes the draft and stops. The user has to tap the same row again to insert it. While it runs, the row shows no progress, and a second tap is silently ignored. | Tapping an untranscribed row means transcribe and insert into this field (if the input token is unchanged). Show a small progress indicator on that row. |
| F12 | med | Drafts | `ime/Panel.kt:74-75`; `AppServices.kt:168-171`; `drafts/DraftStore.kt:100`; `ui/MainActivity.kt:233-236` | "Nothing heard" drafts are hidden from the panel and skipped by auto-retry, but stay PENDING forever. Pending drafts are never pruned. The app's list grows, and "None: every recording reached a field" never shows again. | On NOTHING_HEARD: show "Nothing heard · Retry" once on the panel, then mark the draft CANCELLED (the audio is kept for `keepDays`). In the app, add "Clear nothing-heard". |
| F13 | med | Ergonomics | `ime/Panel.kt:91-99` | The status column has `weight(1f)`, so the mic sits at the left edge (12 dp in), not in the centre. That's a stretch for a right thumb on a 6.7" phone. Cancel is at the far top-right. | Put the mic bottom-centre (or offer a left/right-handed setting). Status goes above the mic. Keep Cancel/Undo next to the mic, not in the far corner. |
| F14 | med | First run | `ui/MainActivity.kt:113-126` | The setup section shows the same buttons whatever the state: nothing says whether the keyboard is enabled or selected. "Allow microphone" does nothing once the user has denied it twice (no rationale or settings fallback, `:67,116`). | Make it a checklist with live state: mic ✓, keyboard enabled ✓ (`enabledInputMethodList`), selected ✓, profile ✓, model ✓. Collapse it once everything is ✓. When the permission dialog won't show anymore, open `ACTION_APPLICATION_DETAILS_SETTINGS`. |
| F15 | med | First run | `ime/DictationIme.kt:153-157` | Pressing the mic without the permission jumps straight into the app with no explanation, and afterwards the user has to find the original field again. | Show "Microphone not allowed · Open Nixconf" on the panel (one tap to open). Better: a small translucent-free permission activity that asks and then `finish()`es back to the field. |
| F16 | med | Profile | `profile/ProfileStore.kt:31-33`; `profile/Profile.kt:40-41`; `ui/MainActivity.kt:151-154,166` | Fetch errors are swallowed. A profile newer than the app (`UnsupportedProfile`) is invisible: the app keeps using the cached one, and nobody is told to update. "Save & fetch" gives no feedback. Test only says "not reachable". | Keep the last fetch error (HTTP code, DNS, unsupported version) and show it in the Profile section, with "Update the app" for a newer profile version. Merge "Save & fetch" and "Test" into one **Save & test**. |
| F17 | med | Profile | `AppServices.kt:111` | `onOpen(force = true)` returns the running job if one is active, so "Save & fetch" right after opening the app can quietly fetch the old URL with the cache rules. | Cancel and restart when `force`, or queue a forced refresh after the running job. |
| F18 | med | App screen | `ui/MainActivity.kt:91-97` | The drafts list, the only recurring task in the app, comes after four setup cards. | Show pending drafts first when there are any. Setup and the model go below, collapsed when done. |
| F19 | med | App screen | `ui/MainActivity.kt:253-266` | Four TextButtons in a non-wrapping `Row`. "Transcribing…" widens the first one, so on a ~360 dp-wide window (or at a large font scale) "Discard" gets pushed off or clipped. Retry stays enabled on drafts that already have text, and it silently overwrites the clipboard (`:258`). | Show one primary action per state (has text → **Copy**; no text → **Transcribe**), and put Share audio, Discard and Retry in an overflow or a `FlowRow`. Show "Copied". Don't copy as a side effect of Retry. |
| F20 | med | App screen | `ui/MainActivity.kt:285-294` | Discard is instant, with no undo. | Add a snackbar with **Undo** (set the draft back to PENDING). |
| F21 | med | A11y | `ime/Panel.kt` (whole) | No haptics. Start and stop happen while the user looks at the field, not the panel. | `HapticFeedbackType.LongPress`/`Confirm` on start, a lighter tick on stop and delivery, a distinct one on Kept or error. Respect the system haptics setting. |
| F22 | med | A11y | `ime/Panel.kt:143-163` | State changes aren't announced. TalkBack users (and eyes-free use) don't hear "Transcribing", "Kept as draft" or "Typed". | `Modifier.semantics { liveRegion = LiveRegionMode.Polite }` on the status slot. Short phrases ("Typed", "Saved as draft: no server"). |
| F23 | low | A11y | `ime/Panel.kt:134-138,155` | The mic's `contentDescription` is merged with its glyph text ("●"/"■"), so TalkBack may read both. The level bar is a `LinearProgressIndicator` with range semantics, updated 10 times a second. | Use `clearAndSetSemantics` on the mic (description + state: "Recording, 0:12"). Mark the level meter as decorative (`clearAndSetSemantics {}`) and draw it as a meter, not a progress bar. |
| F24 | low | Visual | `ime/Panel.kt:82,138` | "⌨" and "●"/"■" are text glyphs. They render as emoji or font fallbacks that differ by OEM and font scale. | Use vector icons (keyboard, mic, stop) from a small `res/drawable` set, so there's no `material-icons-extended` dependency. |
| F25 | low | Visual | `ime/Panel.kt:178-179` | Pending rows are 8 dp + one line of text ≈ 36 dp tall: under the 48 dp target. | `heightIn(min = 48.dp)` on each row. |
| F26 | low | Visual | `ime/Panel.kt:111-112`; `drafts/DraftStore.kt:100` | The panel lists drafts oldest first. The one the user most likely wants to insert (the newest) is at the bottom of a 180 dp list. | Reverse the order on the panel (the app list can stay oldest first or match). Show the age ("2 min ago"). |
| F27 | low | Visual | `ui/Theme.kt:11-15`; `ime/Panel.kt:121-128` | Stock Material You: wallpaper colours, Roboto, a saturated filled mic at rest. The desktop system (`2026-11-17-design-system.md`) is "one ink on paper": achromatic chrome, ink only for live or input states, emphasis by inversion, IBM Plex, radii 6/8, a 4 px spacing scale. | Idle mic: tonal or outlined (paper). Recording: the one filled/ink element (the current `error` red works as "live"). Bundle IBM Plex Sans (OFL) in `res/font`. Use radius 6 for controls and 8 for panels, and hairline dividers. Palette options are under "Larger changes". |
| F28 | low | Visual | `ui/MainActivity.kt:86-97`; `AndroidManifest.xml:13` | targetSdk 36 makes the activity edge-to-edge on Android 15+, but no insets are applied: the title (24 dp top padding) can sit under the status bar or cutout, and the last card under the gesture bar. The manifest theme `Theme.Material.NoActionBar` is the dark framework theme, so light mode starts with a dark flash. *Verify on device.* | Use `Modifier.windowInsetsPadding(WindowInsets.safeDrawing)` or `contentPadding` instead of the empty `Text` at `:97`. Use `Theme.DeviceDefault.DayNight.NoActionBar` (or `Light` + `values-night`) for the window theme. |
| F29 | low | Ergonomics | `ime/DictationIme.kt` (no `onEvaluateFullscreenMode`) | By default, `InputMethodService` goes fullscreen (extract mode) in landscape, which puts a large plain edit box above the panel. | Override `onEvaluateFullscreenMode() = false`. |
| F30 | low | Language | `ime/DictationIme.kt:58,98`; `ime/Panel.kt:84-86` | The language toggle is fine, but the choice lives only in the service (lost when it's destroyed). Recording and Kept states don't show the language. TalkBack reads "EN" as a word. | Show the language in the status line ("0:04 · butternut · AR"). Remember the last choice (per app package, optionally). Add a content description: "Language English, double-tap to switch". |
| F31 | low | Model | `ui/MainActivity.kt:175-191`; `AppServices.kt:119`; `model/ModelDownloader.kt:20` | The download only runs while the app or keyboard process lives, which the UI doesn't say. The Missing state shows two overlapping sentences. "Download now" doesn't say it uses mobile data. There's no cancel. "Parakeet ready (English, offline)" is hardcoded although the model comes from the profile. | Copy: "Waiting for Wi-Fi · 650 MB · continues while Nixconf is open". Button: **Download on mobile data**. Add a cancel. Build "Ready" from `localModel.name`/`language`. |
| F32 | low | Update | `ui/MainActivity.kt:196-231`; `update/Installer.kt:47` | The first tap opens "Install unknown apps" with no explanation, and the user has to tap Update again afterwards. "Downloading…" shows no progress. Versions are short git revs ("1a2b3c → 4d5e6f"). | One sentence before the settings jump. Show "build N" (the versionCode is a commit count) and progress. Re-check on resume. |
| F33 | low | Errors | `ime/DictationIme.kt:159-164,170` | Every start failure becomes "Microphone: …", including a draft directory that can't be created. "No field to type into" also shows when the draft was already delivered from the app. Messages use the body style, not the error colour. | Map exceptions to plain messages ("Microphone in use by another app", "Storage full"). Use a separate message for "already delivered". Style errors with `colorScheme.error` plus an icon. |
| F34 | low | IME config | `res/xml/method.xml:5-8` | The voice subtype is right. `android:isAuxiliary` is unset, so the IME takes part in the "next keyboard" rotation. | Evaluate `isAuxiliary="true"` for the voice subtype: aux IMEs are skipped by the next-IME cycling, which suits a dictation-only keyboard. *Verify how the HyperOS switcher treats it* before changing. |

What already works and should be kept: a latch mic at 80 dp; the engine
label during recording; switching disabled while recording (never records
unseen); the pending chip hidden while active; M3 `TextButton`s, which meet
48 dp through `minimumInteractiveComponentSize`; `sp` text everywhere; the
4 px spacing (12/8/16) in the panel; the app screen opening as the IME's
settings activity.

## Copy

| Where | Now | Suggested |
|---|---|---|
| `ime/Panel.kt:104` | No profile yet: open Nixconf on the tailnet once | No profile: connect to the tailnet; retries when the keyboard opens |
| `ime/PanelText.kt:12` | checking… | finding server… |
| `ime/PanelText.kt:15` | no server | no server · will save as draft |
| `ime/PanelText.kt:45` | Field changed: kept as draft | Saved as draft (field changed) · **Insert here** |
| `ime/PanelText.kt:46` | No server: kept as draft | Saved as draft: no server. Transcribes when one is back |
| `ime/PanelText.kt:47` | Nothing heard | Nothing heard: check the level bar · **Retry** |
| `ime/PanelText.kt:48` | On-phone transcription failed: kept as draft | On-phone transcription failed: saved as draft |
| `ime/DictationIme.kt:163` | Microphone: microphone busy | Microphone in use by another app |
| `ime/Panel.kt:111` | 2 pending | 2 drafts |
| `ime/Panel.kt:182` | No text yet: tap to transcribe | Not transcribed · tap to transcribe and insert |
| `ui/MainActivity.kt:177` | Comes with the profile | Waiting for the profile |
| `ui/MainActivity.kt:180-182` | Not downloaded: not on an unmetered network; download now to use mobile data / Downloads by itself on Wi-Fi; about 650 MB. / Download now | Waiting for Wi-Fi · 650 MB / **Download on mobile data** |
| `ui/MainActivity.kt:154,169` | Save & fetch · Test | **Save & test** |

"Kept" (code) vs "draft" (UI): pick **draft** everywhere in the UI, and
say "saved" rather than "kept".

## Prioritised fixes

### Quick wins (small, local changes)

1. **F1**: a `Finishing` state right at stop ("Stopped · finding server…").
2. **F2**: queue the keyboard switch until the text is typed (or disable it
   while transcribing).
3. **F4**: password guard (disable the mic, no draft); warn in number,
   phone and date fields; incognito means no stored draft.
4. **F10**: fallback when `switchToPreviousInputMethod()` returns false
   (next IME, then the picker).
5. **F7**: reset `Done` (and stale `Kept`) on a new input.
6. **F6, F11**: Insert here / Copy inline for a Kept draft with text;
   tapping an untranscribed row transcribes and inserts.
7. **F9**: the engine label switches to "on phone" when the fallback runs.
8. **F21, F22, F23**: haptics on start, stop and result; `liveRegion` on the
   status; clean semantics for the mic and the level meter.
9. **F25, F26, F29, F33**: 48 dp rows, newest-first on the panel, no
   landscape fullscreen, plain error messages.
10. **F28**: DayNight window theme and insets on the app screen.
11. **F19, F20**: per-state primary action, overflow for the rest, undo on
    discard.
12. Copy table above.

### Larger changes

1. **F3 + F13 + F5**: re-lay out the panel at a fixed height, close to the
   system keyboard's: the status slot at the top, the mic bottom-centre (or
   a handedness setting), and one key row (⌫, space, action key) plus
   Cancel/Undo within thumb reach. The drafts view replaces the main view
   inside the same height.
2. **Undo after delivery**: keep `lastCommitted` and offer **Undo** for
   about 5 s in Done. It runs `deleteSurroundingText(len + 1, 0)` only if
   `getTextBeforeCursor` still ends with that text.
3. **F8**: cancel semantics: discard with Undo while recording, "Stop
   waiting (keep draft)" while transcribing.
4. **Fewer taps per burst**: two settings, *Start recording when the
   keyboard opens* and *Return to the previous keyboard after typing*. With
   a keyboard that has a voice key that switches to voice-subtype IMEs
   (HeliBoard, FlorisBoard, AOSP), a burst becomes: voice key → speak →
   stop → back automatically.
5. **F14 + F15 + F16 + F18**: rework the app screen: drafts first, a live
   setup checklist that collapses, profile errors surfaced (including
   "update the app"), a permission flow that returns to the field.
6. **F12**: draft hygiene: auto-cancel nothing-heard drafts, in-app audio
   playback so audio-only drafts can be judged, a "clear" action.
7. **F27**: desktop look. Option A (smallest): keep Material You colours
   but apply the desktop structure (Plex, radius 6/8, hairlines, ink only
   on live states). Option B: generate a `Palette.kt` (light and dark roles)
   from `self.palettes.catppuccin` at build time through `phone-app`, so it
   comes from Nix and has no hardcoded hex, and add the app to
   `checks.design-contrast`. Option C: the profile carries the serving
   host's palette roles, so the phone follows the desktop's wallpaper mode.
   Recommendation: A now, B when the panel layout settles. C only if
   wallpaper mode becomes the default on the desktops.

## Segmented and streaming dictation: how the panel should present it

This is for the parallel pause-segments work: segments are cut at pauses
and transcribed while recording, and an optional "stream" mode shows the
growing text as composing text. The guiding rule is the same as the
desktop's: **calm, one live element, fixed geometry**.

**State model.** Extend `Recording`, don't add parallel states. Add
`segments: SegmentProgress(done, inFlight, failed)` and
`liveTail: String?` (the last finished segment's text, for batch mode).
Add one `Finishing(done, total)` state after stop (this also fixes F1).
`Kept` gains `delivered: Int`, the number of segments already typed.

**While recording (both modes).**
- Status line: `0:42 · butternut · 3 segments` (or `3 ✓ · 1 …` when one
  is in flight). Text, not animation.
- Segment strip under the level meter: one small tick per segment. A
  filled tick means transcribed, an outlined tick in flight, a tick in the
  error colour failed (kept for retry). Give it a fixed height. It
  truncates to the last N ticks and never wraps, so the panel height
  doesn't change.
- Pause cut feedback: the level meter shows a brief hairline marker where
  a segment was cut. No sound, and no haptic per segment (too noisy for a
  calm UI). The only haptics stay at start, stop and result.
- **Batch mode**: the status slot shows `liveTail`, ellipsised from the
  start ("…and then deploy butternut"), so the user can see it is working
  without looking at the field. **Stream mode**: the field already shows
  the text, so the panel shows only counts. Don't duplicate the text.
- Engine changes mid-session (a segment falls back to the phone) update
  the label to "on phone" for the rest of the session (see F9).

**Stream mode in the field.**
- Commit each finished segment (`commitText`) and keep only the segment
  still being transcribed as composing text (`setComposingText`). Composing
  text is fragile in WebViews and chat apps, and a field that loses focus
  usually commits whatever is composing. Keeping composing text to one
  segment limits the damage.
- Before each commit, check the input token as today. If it changed,
  later segments go to the draft, and `Kept` says "3 of 5 segments typed:
  rest saved as draft · **Insert here**". The draft records how much was
  delivered, so it is never typed twice.
- Off automatically in password, number, phone and date fields (F4), and
  in incognito fields.
- Stream is a setting (default off, matching the desktop's batch default),
  with an indicator on the panel ("STREAM" next to the language) so the
  current mode is visible.

**After stop.**
- `Finishing`: the mic turns into a determinate ring (`done/total`
  segments), with the status "Finishing · 2 of 5". Where Cancel was, show
  **Stop waiting**: it keeps the rest as a draft and types nothing more.
- Done: haptic, then the text (batch) or "Typed 5 segments" (stream), with
  **Undo** for about 5 s.

**Cancel and undo.**
- Cancel while recording: discard the whole session. In stream mode,
  remove what this session typed (the committed segments plus the composing
  text), but only if the text before the cursor still matches, using the
  same check as Undo. Show an Undo chip for 5 s (the draft is restorable
  until pruned).
- **Undo** after Done removes the whole dictation, not just the last
  segment, using the same check.
- Optional, stream mode only: **⌫ segment** while recording drops the
  last finished segment (mis-heard, or "scratch that"), using the same
  check. Put it next to the mic in the key row from "Larger changes" #1.

**Failures and background work.**
- A failed segment never stops recording. It falls back to the phone if
  it can, or is marked failed (red tick) and retried once at stop. A
  session with failed segments ends as one draft (one row in the drafts
  list: "segment 2 of 5 failed · Retry"), not one draft per segment.
- Transcription of segments runs while the panel is visible. If the
  keyboard is hidden mid-session, recording stops as today, and segments
  already in flight finish and go to the draft (not the field) when the
  token changed.

**Accessibility.**
- `liveRegion` announcements on segment progress, throttled to at most one
  every 5 s, plus the final result. Never per tick.
- Content description for the strip: "3 of 4 segments transcribed".
