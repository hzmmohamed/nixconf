# Voice diary plan 1: capture on the phone (D0a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Diary module in Pollen that records voice entries in one tap (lock screen, Quick Settings tile, widget, nudge), stores them encrypted on the phone (Opus audio, mood, two dates), plays them back after unlocking, and nudges daily and weekly. Nothing leaves the phone yet.

**Architecture:** A new package `nixconf.phone.diary` beside `ime`, `session`, `audio`. Each entry is one directory holding a sealed metadata file and a sealed audio frame log. Every entry gets its own AES-256-GCM key, wrapped with RSA-OAEP to two public keys: a Keystore device key, whose private half needs the user's unlock, and an optional offline **recovery key** kept in the vault. So recording works from the lock screen without ever being able to read anything back, and a lost Keystore key doesn't mean a lost diary. Plan 2 re-seals these entries into attn's frame-log format and uploads them, once attn's `tracker-lib` and the S3 stack exist.

**Tech Stack:** Kotlin 2.2.21, AGP 8.13.2, compileSdk 36 / minSdk 31, Jetpack Compose (BOM 2025.12.01), kotlinx-serialization 1.9.0, coroutines 1.10.2, JUnit 4.13.2. Platform APIs only: `MediaCodec` (Opus, API 29+), `AndroidKeyStore`, `android.hardware.biometrics.BiometricPrompt`, `TileService`, `AppWidgetProvider`, `AlarmManager`. **No new Gradle dependencies.** The recovery tool is Python 3 with `cryptography`, run through `nx --py cryptography`.

**Spec:** `docs/plans/2026-11-28-voice-diary-design.md` (§5.3, §5.4, §5.5, §5.11, §5.15, §5.16, §6 D0). Shaping notes: `2026-11-28-knowledge-and-diary-brainstorm.md` §A.

## Deviation from the spec (my call, stated to the user with this plan)

The spec's D0 seals entries in attn's frame-log format (age) and uploads them from day one. That needs attn's Kotlin `tracker-lib`, the S3 stack and enrolment, and none of these exist yet. This plan splits D0:

- **D0a (this plan):** capture, a local encrypted store, playback, nudges. A recovery key covers the risk of losing the Keystore key.
- **D0b (plan 2):** re-seal entries to attn frames (diary-brain + vault recipients) and upload.

The local format stays **one entry per directory**, so the purge rule (§5.16) carries over unchanged.

## Global Constraints

- No commercial model or agent ever reads a real entry. Tests use synthetic audio (sine waves) and test-only keys generated in the test.
- **No plaintext at rest.**
  - Entry metadata and audio are only ever written sealed.
  - Plaintext lives in memory only. That includes no temp files, no `cacheDir` WAVs and no logs that hold entry content.
  - `Log` calls in `diary/` print ids and sizes only.
- **Capture never depends on unlock, network or the brain.** Writing an entry needs only public keys.
- **Every entry has its own random 256-bit AES-GCM key**, wrapped with RSA-OAEP (SHA-256, MGF1-SHA-256) to each recipient. Both recipients are RSA-3072.
- **The Diary module is excluded from Android backup** (`files/diary/`). Nothing goes to Google Drive, not even ciphertext.
- **No new Gradle dependencies.** Use platform APIs only. The build has no lock file and fetches online, so every new dependency is a review item.
- **Notification text never contains entry content.** Fixed copy: daily nudge "Anything for the diary?", weekly nudge "Time for the weekly review", recording notification "Recording a diary entry".
- **No streaks or missed-day counts** anywhere.
- Tests: `nix run .#phone-app -- test` (JVM, `testDebugUnitTest`), only on butternut. The Python recovery test runs with `nx --py cryptography -- -m unittest discover -s apps/phone/tools/tests`.
- Kotlin style follows the module: comments say why, `// ...` style, small files.

## Review Focus

1. **Killed mid-recording** (Xiaomi kills, battery dies). Every frame flushed before the kill must survive. A truncated last frame is dropped and everything before it plays. The entry shows up as "interrupted", never lost. Test: Task 3 `truncated_tail_keeps_earlier_frames`, Task 4 `interrupted_entry_is_listed`.
2. **The Keystore key becomes unusable** (screen lock removed, key invalidated). The diary says so plainly ("This phone's key is gone; entries can be read with your recovery key") instead of crashing. New recordings still work under a new device key. Test: Task 6 `unwrap_failure_reports_key_lost`; manual check in Task 6.
3. **The phone is locked when recording starts from the tile or lock screen.** Recording and the mood tap work. Opening the list asks for unlock. Manual check in Task 7. Test: Task 4 `create_and_write_need_no_private_key`.
4. **Mixed Arabic/English, and the clock or time zone changing** (travel, DST). Mood words and future typed text round-trip as UTF-8. Entries sort by `about`, then `recordedAt` in UTC, with the zone kept per entry. Nudges fire once per local day across DST. Tests: Task 1 `utf8_arabic_roundtrip`, Task 9 `daily_across_dst_fires_once`.
5. **Storage nearly full.** A failed write keeps what was flushed and ends the recording with a visible "storage full" message, never a crash or a silent stop. Test: Task 5 `sink_failure_stops_and_reports`.

---

## File structure

```
apps/phone/app/src/main/java/nixconf/phone/diary/
  Ulid.kt               ULID ids (time-sortable)
  Entry.kt              Entry, About, Kind, Mood, Codec + JSON
  EntryCipher.kt        per-entry key, RSA-OAEP wrapping, GCM frames, file header
  EntryStore.kt         one dir per entry: create, append audio, write meta, list, read, hide
  DiaryRecording.kt     PCM → encoder → sealed audio; the recording state machine
  OpusEncoder.kt        MediaCodec Opus encoder (AudioEncoder impl) + PCM fallback
  OpusPlayer.kt         sealed frames → MediaCodec decoder → AudioTrack
  DeviceKeys.kt         AndroidKeyStore RSA key, unlock window, recovery key PEM
  MicRoute.kt           prefer the earbuds' mic while recording
  DiaryService.kt       microphone foreground service
  RecordActivity.kt     show-when-locked entry point: starts the service, record UI, mood tap
  RecordTile.kt         Quick Settings tile
  RecordWidget.kt       home-screen widget (RemoteViews)
  Nudges.kt             next-trigger math + AlarmManager scheduling + receivers
  ui/DiaryActivity.kt   unlock, Home (strip + list), Entry, Settings
  ui/MoodPicker.kt      the 1–5 + words control, shared by Record and Entry
  ui/WeekStrip.kt       last 7 days from mood taps (pure model + composable)
apps/phone/app/src/main/java/nixconf/phone/audio/PcmSink.kt   (new interface)
apps/phone/app/src/main/res/xml/data_extraction_rules.xml, backup_rules.xml, record_widget.xml
apps/phone/app/src/main/res/layout/record_widget.xml
apps/phone/app/src/test/java/nixconf/phone/diary/*Test.kt
apps/phone/app/src/test/resources/diary/golden/      (fixture, test keys only)
apps/phone/tools/diary_recover.py, apps/phone/tools/tests/test_diary_recover.py
```

Modified: `audio/Recorder.kt`, `audio/WavWriter.kt`, `session/DictationSession.kt` (AudioSource signature), `test/.../DictationSessionTest.kt` (fake), `AppServices.kt`, `AndroidManifest.xml`, `ui/MainActivity.kt` (a "Diary" row), `res/values/strings.xml`.

---

### Task 1: Entry model and ULIDs

**Files:**
- Create: `diary/Ulid.kt`, `diary/Entry.kt`
- Test: `test/.../diary/UlidTest.kt`, `test/.../diary/EntryTest.kt`

**Interfaces:**
- Produces:
  - `object Ulid { fun next(nowMs: Long, random: java.util.Random = SecureRandom()): String }`: 26 chars, Crockford base32, monotonic within the same millisecond.
  - `@Serializable data class Entry(val id: String, val recordedAt: Long /*UTC ms*/, val zone: String /*IANA*/, val about: About? = null, val kind: Kind, val codec: Codec? /*null for typed*/, val codecConfig: String? = null /*base64 Opus CSD*/, val durationMs: Long = 0, val mood: Mood? = null, val text: String? = null, val state: State = State.Recording, val hidden: Boolean = false, val format: Int = 1)`
  - `@Serializable sealed interface About { @SerialName("day") data class Day(val date: String /*YYYY-MM-DD*/); @SerialName("range") data class Range(val from: String, val to: String) }`
  - `enum class Kind { spoken, typed }` (later plans add `read_from_paper`, `imported_audio`, `imported_text`, `review`).
  - `enum class Codec { opus, pcm_s16le }`, `enum class State { Recording, Done, Interrupted }`
  - `@Serializable data class Mood(val scale: Int? /*1..5*/, val words: List<String> = emptyList(), val source: String = "user")`
  - `val DiaryJson: Json` (`ignoreUnknownKeys = true`, `encodeDefaults = true`, `classDiscriminator = "type"`)
  - `fun Entry.sortKey(): String`: the `about` start date (or the local date of `recordedAt` in `zone`), then `recordedAt`.

- [ ] **Step 1: Write the failing tests**
  - `UlidTest.length_and_alphabet`: 26 chars, matching `[0-9A-HJKMNP-TV-Z]{26}`.
  - `UlidTest.sorts_by_time`: `next(1000) < next(2000)` as strings.
  - `UlidTest.monotonic_same_ms`: 1000 calls at `nowMs = 5` are strictly increasing.
  - `EntryTest.json_roundtrip_with_about_range`: an `Entry` with `About.Range("2024-01-01","2024-03-31")` and `Mood(4, listOf("calm"))`, encoded and decoded, compares equal. The JSON has `"type":"range"`.
  - `EntryTest.utf8_arabic_roundtrip`: `Mood(null, listOf("هادي", "light"))` and `text = "ابني flake جديد"` survive bytes → string → decode.
  - `EntryTest.unknown_fields_ignored`: decoding `{..., "future": 1}` works.
  - `EntryTest.sort_by_about_then_recorded`: three entries (recorded 2026-11-28 about `Day("2024-05-01")`; recorded 2026-11-27; recorded 2026-11-28 10:00 in `Africa/Cairo`). Sorted by `sortKey()` descending, the order is 28th, 27th, then the 2024 entry.
- [ ] **Step 2: Run** `nix run .#phone-app -- test -- --tests 'nixconf.phone.diary.*'`. Expected: FAIL (unresolved references).
- [ ] **Step 3: Implement** `Ulid.kt` and `Entry.kt` as specified. Monotonic ULIDs increment the random part when the millisecond repeats.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Pollen diary: entry model and ULIDs" -- apps/phone/app/src/main/java/nixconf/phone/diary apps/phone/app/src/test/java/nixconf/phone/diary`

### Task 2: EntryCipher, the sealed file format

**Files:**
- Create: `diary/EntryCipher.kt`
- Test: `test/.../diary/EntryCipherTest.kt`

**Format** (version 1, all integers big-endian). It is written down here because the recovery tool (Task 4) reads it too:

```
header:  magic "PDY1" | u8 recipient_count | per recipient: u8 id_len, id (ascii, e.g. "device:diary-device-v1", "recovery:<fingerprint>"),
         u16 wrapped_len, wrapped (RSA-OAEP-SHA256 of the 32-byte entry key) | 4-byte nonce_prefix
frames:  repeated  u32 ct_len | ct  (AES-256-GCM, nonce = nonce_prefix ‖ u64 frame_index,
         AAD = "PDY1" ‖ file_role byte (0x01 meta, 0x02 audio) ‖ u64 frame_index)
```

A meta file has exactly one frame. An audio file has one frame per flushed chunk. Each audio frame's plaintext is a sequence of `u16 len | opus packet` (or raw PCM16LE bytes when `codec = pcm_s16le`). Readers stop at the first frame that is short or fails authentication, and keep everything before it.

**Interfaces:**
- Produces:
  - `class Recipient(val id: String, val publicKey: java.security.PublicKey)`
  - `class EntryKey private constructor(...)` with `fun header(): ByteArray` and companion functions `new(recipients: List<Recipient>, random: SecureRandom = SecureRandom()): EntryKey` and `open(header: Header, privateKey: PrivateKey, idPrefix: String): EntryKey`. `open` tries every recipient whose id starts with `idPrefix` (`"device:"` or `"recovery:"`) and throws `KeyUnavailable` when none unwraps.
  - `class FrameWriter(out: java.io.OutputStream /*positioned after the header*/, key: EntryKey, role: Byte) { fun write(plain: ByteArray); val frames: Long }`
  - `class FrameReader(input: java.io.InputStream /*positioned after the header*/, key: EntryKey, role: Byte) : Iterator<ByteArray>`: stops cleanly at truncation or a failed tag.
  - `fun readHeader(input: InputStream): Header` (`recipients: Map<String, ByteArray>`, `noncePrefix`).
  - `class KeyUnavailable(cause: Throwable) : Exception`
  - `const val ROLE_META: Byte = 1`, `const val ROLE_AUDIO: Byte = 2`

- [ ] **Step 1: Write the failing tests.** Each test makes its keys with `KeyPairGenerator.getInstance("RSA").initialize(3072)`.
  - `roundtrip_two_recipients`: recipients `device:diary-device-v1` and `recovery:abcd`. Write a header plus 3 frames to a `ByteArrayOutputStream`. Read back with `open(h, devicePriv, "device:")` and with `open(h, recoveryPriv, "recovery:")`. Both give the same 3 plaintexts.
  - `wrong_private_key_throws_key_unavailable`
  - `truncated_tail_keeps_earlier_frames`: drop the last 5 bytes. The reader yields 2 frames and doesn't throw.
  - `tampered_frame_stops_there`: flip a byte in frame 2. The reader yields frame 1 only.
  - `frames_not_reorderable`: swap frames 1 and 2. The reader yields nothing past frame 0, because the AAD index is checked.
  - `meta_frame_not_readable_as_audio`: a frame written with `ROLE_META` fails under `ROLE_AUDIO`.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement** with `Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")` using an explicit `OAEPParameterSpec("SHA-256","MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT)`, so Android Keystore and JCA agree on MGF1-SHA-256, and `AES/GCM/NoPadding` with a 128-bit tag.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `"Pollen diary: sealed entry format (per-entry key, RSA-OAEP, GCM frames)"`

### Task 3: EntryStore

**Files:**
- Create: `diary/EntryStore.kt`
- Test: `test/.../diary/EntryStoreTest.kt`

Layout: `<root>/<entryId>/meta.pdy` (rewritten atomically: write `meta.pdy.tmp`, fsync, rename) and `<root>/<entryId>/audio.pdy`. Each entry has one key. The header is stored in both files, so either file can be opened alone.

**Interfaces:**
- Consumes: Task 1 `Entry`, Task 2 `EntryKey`, `FrameWriter`, `FrameReader`, `Recipient`.
- Produces:
  - `class EntryStore(root: File, recipients: () -> List<Recipient>, now: () -> Long)`
  - `fun create(kind: Kind, codec: Codec, zone: String): OpenEntry`. Needs public keys only.
  - `class OpenEntry { val entry: Entry; fun appendAudio(chunk: ByteArray) /*one frame, fsync*/; fun update(f: (Entry) -> Entry) /*re-seals meta from the in-memory copy, no private key*/; fun finish(durationMs: Long) /*state = Done*/ }`
  - `fun list(privateKey: PrivateKey): List<Listed>`, where `data class Listed(val entry: Entry?, val id: String, val error: String?)`. An entry whose meta can't be opened is still listed with an error. An entry left in `Recording` with no live writer is reported as `Interrupted`.
  - `fun openForRead(id: String, privateKey: PrivateKey): ReadEntry`, with `ReadEntry { val entry: Entry; fun audioFrames(): Iterator<ByteArray>; fun update(f: (Entry) -> Entry) }`
  - `fun setHidden(id: String, hidden: Boolean, privateKey: PrivateKey)`
  - `var activeId: String?`: the entry being recorded. `list` skips it, as `DraftStore.pending` does.

- [ ] **Step 1: Write the failing tests** (`TemporaryFolder`, software RSA keys):
  - `create_and_write_need_no_private_key`: `create`, `appendAudio` ×3, `update { it.copy(mood = Mood(3)) }` and `finish(1500)` run with a store that only has public recipients. `list(devicePriv)` then shows mood 3, `Done`, `durationMs` 1500.
  - `no_plaintext_on_disk`: write meta with `text = "SECRET-هادي"` and an audio chunk of the ASCII bytes `"PLAINAUDIO"`. Neither string appears in any file under `root`, in UTF-8 or in UTF-16.
  - `meta_rewrite_is_atomic`: if a stale `meta.pdy.tmp` is left behind, `list` ignores it and still reads the last good meta.
  - `interrupted_entry_is_listed`: create plus 2 chunks, then drop the `OpenEntry` without calling `finish`, in a new store instance. `list` reports `Interrupted`, and `audioFrames()` yields 2.
  - `hidden_entries_flagged`: `setHidden(id, true)` shows up in `list`, and the dir still exists.
  - `unreadable_meta_listed_with_error`: corrupt `meta.pdy`. `list` returns `Listed(entry = null, error = ...)` and doesn't throw.
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep the `EntryKey` in the `OpenEntry` so meta can be re-sealed without the private key.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `"Pollen diary: entry store (one dir per entry, atomic meta, interrupted entries)"`

### Task 4: Golden fixture and recovery tool

The recovery path is what makes phone-only storage acceptable, so it gets tested before any UI.

**Files:**
- Create: `test/.../diary/GoldenFixtureTest.kt`, `test/resources/diary/golden/` (generated once, committed; **test keys only**), `apps/phone/tools/diary_recover.py`, `apps/phone/tools/tests/test_diary_recover.py`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - The CLI `python3 diary_recover.py --key recovery.pem --out DIR ENTRY_DIR...` (run as `nx --py cryptography -- apps/phone/tools/diary_recover.py ...`). For each entry it writes `DIR/<id>/meta.json`, plus `audio.ogg` (Ogg Opus with an OpusHead built from the stored codec config) or `audio.wav` (pcm). It reports truncated or failed frames per entry and exits 0 if at least the meta was recovered.

- [ ] **Step 1: Write** `GoldenFixtureTest.golden_matches_format`. It reads `golden/recovery_test_key.pem` (a test-only RSA-3072 private key, committed and named as a test key) and the entry dir `golden/01J.../`. It opens the entry with the recovery recipient and asserts the meta equals `golden/expected_meta.json`, and that the audio frames equal `golden/expected_frames.bin`. Add a `@Ignore`d `generate()` helper that writes the fixture: a 1 s 440 Hz sine as `pcm_s16le` in 2 frames, plus a `Mood(4, ["calm","هادي"])`.
- [ ] **Step 2:** Run `generate()` once (remove the `@Ignore` locally), commit the fixture, restore the `@Ignore`. Run `golden_matches_format`. Expected: PASS.
- [ ] **Step 3: Write** `test_diary_recover.py` (unittest):
  - `test_recovers_golden`: the fixture gives `meta.json` equal to `expected_meta.json`, and `audio.wav` gives 16000 samples.
  - `test_truncated_audio_keeps_first_frame`: copy the fixture and truncate `audio.pdy` by 3 bytes. One frame is recovered, with a warning on stderr.
  - `test_wrong_key_fails_clearly`: a fresh key gives exit code 1 and "cannot unwrap entry key with this recovery key".
- [ ] **Step 4: Run** `nx --py cryptography -- -m unittest discover -s apps/phone/tools/tests`. Expected: FAIL (no module).
- [ ] **Step 5: Implement** `diary_recover.py`: stdlib plus `cryptography` (`padding.OAEP(MGF1(SHA256), SHA256)`, `AESGCM`). Write the Ogg page writer inline (CRC-32 with polynomial 0x04C11DB7, one packet per page is fine). Usage text at the top.
- [ ] **Step 6: Run** both test suites. Expected: PASS.
- [ ] **Step 7: Commit** `"Pollen diary: golden fixture and offline recovery tool"`

### Task 5: Recording pipeline (PCM sink, Opus encoder, DiaryRecording)

**Files:**
- Create: `audio/PcmSink.kt`, `diary/OpusEncoder.kt`, `diary/DiaryRecording.kt`
- Modify: `audio/WavWriter.kt` (`: PcmSink`), `audio/Recorder.kt` (`start(out: PcmSink, ...)`), `session/DictationSession.kt:47-51` (`AudioSource.start(out: PcmSink, ...)`), `test/.../session/DictationSessionTest.kt:76-78` (the fake's signature)
- Test: `test/.../diary/DiaryRecordingTest.kt`

**Interfaces:**
- Produces:
  - `interface PcmSink { fun write(samples: ShortArray, n: Int); fun flush() }`. `WavWriter` already has both.
  - `interface AudioEncoder { val codec: Codec; val config: ByteArray? /*Opus CSD: OpusHead ‖ pre-skip ‖ seek preroll as MediaCodec emits*/; fun encode(samples: ShortArray, n: Int): List<ByteArray>; fun drain(): List<ByteArray>; fun close() }`
  - `class MediaCodecOpusEncoder(sampleRate = 16000, bitrate = 32000, frameMs = 20) : AudioEncoder`: `MediaCodec.createEncoderByType("audio/opus")`.
  - `class PcmPassthrough : AudioEncoder` (`codec = pcm_s16le`): the fallback when no Opus encoder exists, and the encoder the tests use.
  - `fun pickEncoder(): AudioEncoder`: Opus if `MediaCodecList` has an `audio/opus` encoder, else PCM.
  - `class DiaryRecording(store: EntryStore, audio: AudioSource, encoder: () -> AudioEncoder, zone: () -> String, flushMs: Long = 2000, now: () -> Long)`, with `val state: StateFlow<RecState>`, where `sealed interface RecState { Idle; Recording(entryId, startedAt, level); Saved(entryId, durationMs); Failed(entryId?, message) }`, and `fun start()`, `fun stop()`. It implements `PcmSink`: it buffers encoded packets and writes one sealed audio frame per flush. The encoder's `config` goes into `Entry.codecConfig` (base64).

- [ ] **Step 1: Write the failing tests.** Use a fake `AudioSource` that pushes 3 s of sine wave in 100 ms chunks and calls `flush()` every 2 s of samples, `PcmPassthrough`, and a `TemporaryFolder` store.
  - `records_flushes_and_saves`: after `start()`, push and `stop()`, the state is `Saved(id, 3000)`. The store lists the entry as `Done`, and its frames concatenate to the pushed samples.
  - `flush_writes_one_frame_per_interval`: 3 s with `flushMs = 2000` gives 2 frames (one at 2 s, one at stop).
  - `sink_failure_stops_and_reports`: a store whose `appendAudio` throws `IOException("No space left")` on the second call gives `Failed(id, "Storage is full: the recording was saved up to here")`. The first frame stays readable.
  - `start_twice_is_ignored`
- [ ] **Step 2: Run** the tests. Expected: FAIL.
- [ ] **Step 3: Implement** `PcmSink` and the `WavWriter`/`Recorder`/`AudioSource` signature change (the dictation tests must still pass unchanged apart from the fake's parameter type), then `DiaryRecording`, `PcmPassthrough`, and `MediaCodecOpusEncoder` (not JVM-tested).
- [ ] **Step 4: Run** the whole JVM suite (`nix run .#phone-app -- test`). Expected: PASS, including every existing test.
- [ ] **Step 5: Device check, done by the user. Ask for it.** Record 10 s with a debug build and check `logcat` that the codec is `opus`. If the phone has no Opus encoder, `pcm` is the expected fallback: note it in the commit.
- [ ] **Step 6: Commit** `"Pollen diary: recording pipeline (PcmSink, Opus encoder with PCM fallback)"`

### Task 6: Keys, unlock and the recovery key

**Files:**
- Create: `diary/DeviceKeys.kt`
- Test: `test/.../diary/RecoveryKeyTest.kt`, `test/.../diary/KeyStatusTest.kt`

**Interfaces:**
- Produces:
  - `object RecoveryKey { fun parsePem(text: String): Result<PublicKey> /*SPKI "BEGIN PUBLIC KEY", RSA ≥ 3072, else a clear error*/; fun fingerprint(key: PublicKey): String /*first 16 hex of SHA-256(SPKI), grouped by 4*/ }`
  - `class DeviceKeys(context)`:
    - `fun publicRecipients(): List<Recipient>` (device, plus recovery when set; creates the device key on first use);
    - `fun privateKey(): PrivateKey` (throws `UserNotAuthenticatedException` when locked);
    - `var recoveryPem: String?` (SharedPreferences `diary`);
    - `fun status(): KeyStatus`.
  - The device key is RSA-3072 in `AndroidKeyStore`, alias `diary-device-v1`. It's set up with `PURPOSE_DECRYPT`, `DIGEST_SHA256`, `ENCRYPTION_PADDING_RSA_OAEP`, `setUserAuthenticationRequired(true)`, `setUserAuthenticationParameters(300, AUTH_BIOMETRIC_STRONG or AUTH_DEVICE_CREDENTIAL)` and `setInvalidatedByBiometricEnrollment(false)`. Encryption uses the exported public key in software, so it never needs auth.
  - `enum class KeyStatus { Ok, NoRecoveryKey, DeviceKeyLost }`. When the alias is gone or `KeyPermanentlyInvalidatedException` is thrown, the status is `DeviceKeyLost`, and the next `publicRecipients()` creates `diary-device-v2`, or the next number up.
  - `fun keyStatusMessage(s: KeyStatus): String?`. The exact copy:
    - `NoRecoveryKey` → "Entries can only be read on this phone. Add a recovery key in Diary settings."
    - `DeviceKeyLost` → "This phone's key is gone; entries can be read with your recovery key."
    - `Ok` → null.
- Consumes: Task 2 `Recipient`, `KeyUnavailable`. Recipient ids are `"device:<alias>"` and `"recovery:<fingerprint>"`, so older entries stay addressable after a rotation.

- [ ] **Step 1: Write the failing tests:**
  - `RecoveryKeyTest.parses_rsa3072_spki`
  - `RecoveryKeyTest.rejects_rsa2048`: the error says "needs RSA 3072 or larger".
  - `RecoveryKeyTest.rejects_private_key_pem`: "this is a private key; paste the public one".
  - `RecoveryKeyTest.fingerprint_stable`
  - `KeyStatusTest.messages`: exact copy as above.
  - `KeyStatusTest.unwrap_failure_reports_key_lost`: an `EntryStore.list` through a key-provider that throws `KeyPermanentlyInvalidatedException` maps to `DeviceKeyLost`. Put the mapping in a pure function `keyStatusOf(t: Throwable?, recoverySet: Boolean)`.
- [ ] **Step 2: Run** the tests. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Device check, done by the user.** Set a recovery key, record, unlock and list. The offline recovery round trip (export → `diary_recover.py` on hazel with the real key) is checked after Task 8 adds Export. The user runs it; agents never see the output.
- [ ] **Step 6: Commit** `"Pollen diary: Keystore device key, unlock window, recovery key"`

### Task 7: Entry points (service, record screen, tile, widget, earbud mic)

**Files:**
- Create: `diary/DiaryService.kt`, `diary/RecordActivity.kt`, `diary/RecordTile.kt`, `diary/RecordWidget.kt`, `diary/MicRoute.kt`, `diary/ui/MoodPicker.kt`, `res/layout/record_widget.xml`, `res/xml/record_widget.xml`
- Modify: `AndroidManifest.xml`, `AppServices.kt` (adds `val diaryStore`, `val diaryKeys`, `val diaryRecording`), `res/values/strings.xml`
- Test: `test/.../diary/MoodPickerModelTest.kt`

Every entry point opens **`RecordActivity`** (`showWhenLocked`, `turnScreenOn`, `excludeFromRecents`, single task). From the foreground it starts `DiaryService` as a `microphone` foreground service. That avoids Android 14's background-start limits for microphone services, the failure `KeepOnService` handles. The tile uses `startActivityAndCollapse(PendingIntent)`, which API 34+ requires. The widget is one button through `RemoteViews`.

**RecordActivity** shows a timer, a level bar and Stop. After Stop it shows `MoodPicker` (1–5 and words, both skippable: "Skip" and "Save" buttons), then "About when?" (defaults to "Now"; Today / Yesterday / pick a date). Saving the mood calls `OpenEntry.update`. Nothing here needs unlock.

**Interfaces:**
- Consumes: Task 5 `DiaryRecording`, Task 3 `EntryStore`, Task 6 `DeviceKeys`.
- Produces:
  - `object MicRoute { fun preferEarbuds(am: AudioManager): Boolean; fun release(am: AudioManager) }`. It calls `setCommunicationDevice` on the first `TYPE_BLUETOOTH_SCO` / `TYPE_BLE_HEADSET` from `availableCommunicationDevices`, and `clearCommunicationDevice` on release.
  - `data class MoodChoice(val scale: Int?, val words: Set<String>)`, `fun MoodChoice.toMood(): Mood?` (null when both are empty), `val DEFAULT_MOOD_WORDS = listOf("calm","light","heavy","restless","tired","grateful")`.
  - The intent action `nixconf.phone.diary.RECORD` (extra `source`: `tile|widget|nudge|app`).

- [ ] **Step 1: Write the failing tests** in `MoodPickerModelTest`:
  - `empty_choice_is_no_mood`
  - `scale_only`: `MoodChoice(4, emptySet())` gives `Mood(4, [])`.
  - `words_keep_order_of_defaults`: `{"heavy","calm"}` gives `["calm","heavy"]`.
- [ ] **Step 2: Run** the tests. Expected: FAIL. **Step 3: Implement** everything in this task. The manifest adds `RecordActivity`, `DiaryService` (`foregroundServiceType="microphone"`), `RecordTile` (`BIND_QUICK_SETTINGS_TILE`, label "Diary"), the `RecordWidget` receiver, and `MODIFY_AUDIO_SETTINGS` for `MicRoute`. **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Device checks, done by the user. List them in the hand-back.**
  - (a) Locked phone, tile → recording, Stop, mood, saved.
  - (b) Widget → the same.
  - (c) Screen off mid-recording for 2 minutes keeps recording.
  - (d) Earbuds connected → `logcat` shows the SCO/BLE device chosen.
  - (e) Force-stop mid-recording → the entry shows up as interrupted with its audio.
- [ ] **Step 6: Commit** `"Pollen diary: record from tile, widget and lock screen; mood tap"`

### Task 8: Reading and listening (DiaryActivity, week strip, playback)

**Files:**
- Create: `diary/ui/DiaryActivity.kt`, `diary/ui/WeekStrip.kt`, `diary/OpusPlayer.kt`
- Modify: `ui/MainActivity.kt` (a "Diary" section with an Open button), `AndroidManifest.xml` (`DiaryActivity` with its own launcher entry, label "Diary", icon as the app's)
- Test: `test/.../diary/WeekStripTest.kt`, `test/.../diary/ExportTest.kt`

**DiaryActivity:**
- **Unlock:** on open, if `privateKey()` throws `UserNotAuthenticatedException`, show the platform `BiometricPrompt` (allowed authenticators `BIOMETRIC_STRONG or DEVICE_CREDENTIAL`, title "Open your diary"), then load.
- **Home:** the key status banner (Task 6 copy), the week strip, a Record button (→ `RecordActivity`, `source=app`), and the list newest first by `sortKey()`. Each row shows the date, kind, duration, mood and an "interrupted" tag.
- **Entry:** play/pause, elapsed / total, mood (editable with `MoodPicker`), about (editable), Hide.
- **Settings:** recovery key (paste PEM, shows the fingerprint), nudge times (Task 9), Hidden entries (unhide), and **Export sealed entries**. Export shares a zip of the ciphertext through the share sheet, for a manual off-phone copy until plan 2 uploads. It's also the only way to get entries to `diary_recover.py` on a release build, since app-private files can't be pulled. It needs no unlock, because it only copies ciphertext.
- **Typed entry:** a text field on Home ("Write instead"), saved as `Kind.typed`, `codec = null`, no audio file.

**Interfaces:**
- Consumes: Tasks 3, 6, 7.
- Produces:
  - `data class StripDay(val date: LocalDate, val scale: Int?, val entries: Int)`, `fun weekStrip(entries: List<Entry>, today: LocalDate, zone: ZoneId): List<StripDay>`: the 7 days ending today, the mean of user taps rounded half up, `scale = null` when there are none. Hidden entries don't count. Model guesses don't exist yet; the field `Mood.source` keeps room for them.
  - `fun exportSealed(root: File, out: java.io.OutputStream)`: a zip of `<id>/meta.pdy` and `<id>/audio.pdy` only (no `.tmp`), stored without compression.
  - `class OpusPlayer(entry: ReadEntry)` with `fun play()`, `fun pause()`, `val positionMs: StateFlow<Long>`, `val durationMs: Long`, `fun release()`. It decodes via `MediaCodec.createDecoderByType("audio/opus")` with CSD from `Entry.codecConfig` (pcm: feed `AudioTrack` directly). Decoded PCM stays in memory only.

- [ ] **Step 1: Write the failing tests.** In `ExportTest`: `zip_holds_only_sealed_files` (a `.tmp` and a stray file are left out; the names are `<id>/meta.pdy`, `<id>/audio.pdy`) and `export_needs_no_private_key`. In `WeekStripTest`:
  - `seven_days_ending_today`
  - `mean_of_taps_rounded_half_up`: 3 and 4 give 4.
  - `untapped_day_is_null_but_counted`: 2 entries, no mood → `scale = null`, `entries = 2`.
  - `hidden_excluded`
  - `about_date_does_not_move_into_strip`: a backfilled `about` 2024 entry recorded today counts for today's capture, not 2024. The strip is about this week's days of recording. That's my call: the strip shows how this week felt when spoken, and the entry's own mood belongs to it.
- [ ] **Step 2: Run** the tests. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Device check, done by the user.** Play an Opus entry recorded in Task 7. Play an interrupted one. Hide and unhide. Remove the recovery key and see the banner. Export, copy the zip to hazel, unzip it, and run `nx --py cryptography -- apps/phone/tools/diary_recover.py --key <recovery.pem> --out /tmp/r <dirs>`. The `audio.ogg` plays in mpv.
- [ ] **Step 6: Commit** `"Pollen diary: diary screen, week strip, playback"`

### Task 9: Nudges

**Files:**
- Create: `diary/Nudges.kt`
- Modify: `AndroidManifest.xml` (`NudgeReceiver`, `BootReceiver` with `RECEIVE_BOOT_COMPLETED`), `diary/ui/DiaryActivity.kt` (Settings rows)
- Test: `test/.../diary/NudgesTest.kt`

**Interfaces:**
- Produces:
  - `data class NudgeSettings(val dailyOn: Boolean = true, val dailyAt: LocalTime = LocalTime.of(21, 30), val weeklyOn: Boolean = true, val weeklyDay: DayOfWeek = DayOfWeek.SUNDAY, val weeklyAt: LocalTime = LocalTime.of(20, 0))`. Defaults are my call; the user changes them in Settings.
  - `fun nextDaily(now: ZonedDateTime, at: LocalTime): ZonedDateTime`, `fun nextWeekly(now: ZonedDateTime, day: DayOfWeek, at: LocalTime): ZonedDateTime`: strictly after `now`. In a DST gap they take the instant after the gap. In an overlap they take the earlier one.
  - `object Nudges { fun schedule(context, settings) ; fun snooze(context, kind, minutes = 60) }`: `AlarmManager.setWindow(RTC_WAKEUP, t, 10 min, …)`, no exact-alarm permission. Notification channel "Diary reminders". The actions are **Record** (→ `RecordActivity`, `source=nudge`) and **Later** (snooze 1 h). The weekly one opens `DiaryActivity` (the review screen comes in a later plan).
  - The daily nudge is the shared Evening moment of design §5.17. attn's chips join this screen in attn's M1; leave a `// attn chips (design §5.17)` slot comment in `RecordActivity`, no code.

- [ ] **Step 1: Write the failing tests:**
  - `daily_later_today`
  - `daily_tomorrow_when_passed`
  - `daily_exactly_now_goes_to_tomorrow`
  - `weekly_next_sunday`
  - `daily_across_dst_fires_once`: zone `Europe/Berlin`, `now` = 2026-10-24 22:00, `at` = 02:30. The next three calls chained give 10-25 02:30 (first occurrence), 10-26 02:30, 10-27 02:30: one per local day.
  - `daily_in_spring_gap`: `Europe/Berlin` 2027-03-28, `at` = 02:30 → 03:30 that day.
- [ ] **Step 2: Run** the tests. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Device check, done by the user.** Set the daily nudge to 2 minutes ahead. The notification shows the fixed copy. Record works from it. Later re-fires after the snooze (temporarily set to 2 min in a debug build). A reboot keeps the schedule.
- [ ] **Step 6: Commit** `"Pollen diary: daily and weekly nudges"`

### Task 10: Backup exclusion, docs and hand-back

**Files:**
- Create: `res/xml/data_extraction_rules.xml`, `res/xml/backup_rules.xml`
- Modify: `AndroidManifest.xml` (`android:dataExtractionRules`, `android:fullBackupContent`), `docs/plans/2026-11-28-voice-diary-design.md` (§6: D0 split into D0a/D0b, the local format and the recovery key under §5.15, "my call"), `docs/plans/2026-11-17-user-actions.md` (generate the recovery key)
- Test: `test/.../diary/BackupRulesTest.kt`

- [ ] **Step 1: Write the failing test** `BackupRulesTest.diary_excluded_everywhere`. It parses both XML files from `src/main/res/xml/` with the JDK's DOM parser and asserts an `<exclude domain="file" path="diary/"/>` under `<cloud-backup>` and `<device-transfer>`, and under `<full-backup-content>` in `backup_rules.xml`.
- [ ] **Step 2: Run** the test. Expected: FAIL. **Step 3: Write** the XML and the manifest attributes. **Step 4: Run** the full suite. Expected: PASS.
- [ ] **Step 5: Docs.**
  - Update the design doc as listed.
  - Add a user action, a paste-ready bash script run on hazel:

    ```bash
    # Diary recovery key: private half into KeePassXC, public half into Pollen
    set -euo pipefail
    d=$(mktemp -d); trap 'shred -u "$d"/*; rmdir "$d"' EXIT
    nx openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$d/diary-recovery.pem"
    nx openssl pkey -in "$d/diary-recovery.pem" -pubout -out "$d/diary-recovery.pub.pem"
    echo "Attach $d/diary-recovery.pem to a KeePassXC entry 'Diary recovery key' now, then press Enter."
    read -r
    cat "$d/diary-recovery.pub.pem"   # paste into Pollen › Diary › Settings › Recovery key
    ```
- [ ] **Step 6: Run** `just check` (or `nix develop --impure -c just check`) and `nix run .#fleet -- affects`. Expected: OK. Pollen isn't a host, so expect no hosts, or only the phone-profile check.
- [ ] **Step 7: Commit** `"Pollen diary: keep the diary out of Android backup; docs for D0a"`

---

## Later plans (not this one)

- **Plan 2, D0b:** attn `tracker-lib` (Kotlin frame log, age, `opus` frame kind with vectors), the diary S3 prefix and purge role in attn's Alchemy stack, `diary device enrol`, and an upload queue that re-seals local entries into frames to diary-brain + vault.
- **Plan 3, D5 early (if the user wants backfill soon):** a Backfill screen (page photos plus reading aloud, `about` ranges) and share-to-Pollen import of audio and text.
- D1 onward (diary-brain, transcripts, review, search) after peacelily is up.
