package nixconf.phone.session

import java.io.File
import java.io.IOException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import nixconf.phone.audio.WavFiles
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import nixconf.phone.engine.Engine
import nixconf.phone.engine.RemoteTranscriber
import nixconf.phone.profile.LocalModel
import nixconf.phone.profile.MODE_STREAM
import nixconf.phone.profile.Profile
import nixconf.phone.segment.SpeechProbability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(ExperimentalCoroutinesApi::class) // advanceUntilIdle, advanceTimeBy
class DictationSessionTest {
    @get:Rule val tmp = TemporaryFolder()

    private val server = "http://butternut:8178"
    private var profile: Profile? = Profile(
        version = 1,
        servers = listOf(server),
        languages = listOf("en", "ar"),
        prompt = "NixOS, flake.",
        localModel = LocalModel("parakeet", "en", emptyList()),
    )
    private val drafts by lazy { DraftStore(tmp.root, { 1_795_000_000_000L }) }

    private var serverUp = true
    private var probeDelayMs = 0L
    private val remoteCalls = mutableListOf<List<String>>()
    private var remote: suspend (File) -> String = { "hello world" }

    private class FakeLocal(override var ready: Boolean = true, var text: String = "local text") : LocalTranscriber {
        var calls = 0
        override fun transcribe(wav: File): String {
            calls++
            return text
        }
    }
    private val local = FakeLocal()

    // Writes [samples] at start (and taps them, as the recorder does).
    private class FakeAudio(var samples: ShortArray = ShortArray(1600) { 100 }) : AudioSource {
        override val level = MutableStateFlow(0f)
        var recording = false
        override fun start(out: WavWriter, tap: ((ShortArray, Int) -> Unit)?) {
            recording = true
            out.write(samples, samples.size)
            tap?.invoke(samples, samples.size)
        }
        override fun stop() {
            recording = false
        }
    }
    private val audio = FakeAudio()

    private class FakeEditor(override var token: String?) : EditorTarget {
        val commits = mutableListOf<String>()
        val composed = mutableListOf<String>()
        var composing = ""
        override fun commit(text: String): Boolean {
            commits += text
            composing = ""
            return true
        }
        override fun compose(text: String): Boolean {
            composed += text
            composing = text
            return true
        }
    }
    private val editor = FakeEditor("org.notes/42")

    // Speech is any frame with a sample above 0.05 (the fake audio's speech is 3000, ~0.09).
    private class FakeVad : SpeechProbability {
        override fun probability(frame: FloatArray): Float = if (frame.any { kotlin.math.abs(it) > 0.05f }) 0.9f else 0f
    }
    private var vad: (() -> SpeechProbability)? = null

    private fun TestScope.session() = DictationSession(
        profile = { profile },
        drafts = drafts,
        audio = audio,
        remote = RemoteTranscriber { url, wav, language, prompt ->
            remoteCalls += listOf(url, language, prompt)
            remote(wav)
        },
        local = local,
        probe = {
            delay(probeDelayMs)
            serverUp
        },
        scope = this,
        vad = vad,
        io = StandardTestDispatcher(testScheduler),
        clock = { testScheduler.currentTime },
    )

    private fun onlyDraft(): Draft = drafts.load(tmp.root.listFiles()!!.single().name)!!

    private fun TestScope.dictate(s: DictationSession, language: String = "en") {
        s.start(language, editor)
        advanceUntilIdle()
        s.stop()
        advanceUntilIdle()
    }

    @Test
    fun remote_text_committed_and_draft_delivered() = runTest {
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        assertEquals(SessionState.Recording(Engine.Remote(server), 0), s.state.value)
        assertTrue(audio.recording)

        s.stop()
        advanceUntilIdle()
        assertFalse(audio.recording)
        assertEquals(SessionState.Done("hello world"), s.state.value)
        assertEquals(listOf("hello world "), editor.commits)
        assertEquals(listOf(listOf(server, "en", "NixOS, flake.")), remoteCalls)
        val d = onlyDraft()
        assertEquals(DraftStatus.DELIVERED, d.status)
        assertEquals("hello world", d.text)
        assertEquals(server, d.engine)
        assertEquals(1600, WavFiles.readSamples(d.audio).size)
    }

    @Test
    fun engine_shown_once_probes_answer_and_stop_waits_for_them() = runTest {
        probeDelayMs = 1000
        val s = session()
        s.start("en", editor)
        advanceTimeBy(10)
        assertEquals(SessionState.Recording(null, 0), s.state.value)
        s.stop()
        advanceUntilIdle()
        assertEquals(SessionState.Done("hello world"), s.state.value)
    }

    @Test
    fun remote_fails_midway_falls_back_to_local() = runTest {
        remote = { throw IOException("butternut: HTTP 500") }
        val s = session()
        dictate(s)

        assertEquals(SessionState.Done("local text"), s.state.value)
        assertEquals(listOf("local text "), editor.commits)
        assertEquals(1, local.calls)
        val d = onlyDraft()
        assertEquals(DraftStatus.DELIVERED, d.status)
        assertEquals(DictationSession.LOCAL_ENGINE, d.engine)
    }

    @Test
    fun remote_fails_arabic_keeps_pending() = runTest {
        remote = { throw IOException("timeout") }
        val s = session()
        dictate(s, "ar")

        val kept = s.state.value as SessionState.Kept
        assertEquals(DictationSession.NO_SERVER, kept.reason)
        assertTrue(editor.commits.isEmpty())
        assertEquals(0, local.calls)
        val d = onlyDraft()
        assertEquals(DraftStatus.PENDING, d.status)
        assertNull(d.text)
        assertEquals(1600, WavFiles.readSamples(d.audio).size)
        assertEquals(listOf(d), drafts.pending())
    }

    @Test
    fun field_changed_keeps_pending_with_text() = runTest {
        remote = {
            delay(5000)
            "hello world"
        }
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        s.stop()
        advanceTimeBy(1000)
        assertEquals(SessionState.Transcribing(Engine.Remote(server)), s.state.value)
        editor.token = "org.browser/7" // user switched app while transcribing
        advanceUntilIdle()

        val kept = s.state.value as SessionState.Kept
        assertEquals(DictationSession.FIELD_CHANGED, kept.reason)
        assertEquals("hello world", kept.draft.text)
        assertTrue(editor.commits.isEmpty())
        val d = onlyDraft()
        assertEquals(DraftStatus.PENDING, d.status)
        assertEquals("hello world", d.text)
    }

    @Test
    fun hidden_keyboard_keeps_pending() = runTest {
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        s.stop()
        editor.token = null // IME hidden, no field
        advanceUntilIdle()
        assertEquals(DictationSession.FIELD_CHANGED, (s.state.value as SessionState.Kept).reason)
        assertTrue(editor.commits.isEmpty())
    }

    @Test
    fun null_profile_records_and_keeps_draft() = runTest {
        profile = null
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        assertEquals(SessionState.Recording(Engine.Unavailable, 0), s.state.value)
        assertTrue(audio.recording)
        s.stop()
        advanceUntilIdle()

        assertEquals(DictationSession.NO_SERVER, (s.state.value as SessionState.Kept).reason)
        assertTrue(remoteCalls.isEmpty())
        assertEquals(0, local.calls)
        val d = onlyDraft()
        assertEquals(DraftStatus.PENDING, d.status)
        assertEquals(1600, WavFiles.readSamples(d.audio).size)
    }

    @Test
    fun cancel_marks_cancelled_commits_nothing() = runTest {
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        s.cancel()
        advanceUntilIdle()
        assertEquals(SessionState.Idle, s.state.value)
        assertFalse(audio.recording)
        assertTrue(remoteCalls.isEmpty())
        assertEquals(DraftStatus.CANCELLED, onlyDraft().status)

        // While transcribing: the late answer is dropped.
        remote = {
            delay(5000)
            "too late"
        }
        tmp.root.listFiles()!!.forEach { it.deleteRecursively() }
        s.start("en", editor)
        advanceUntilIdle()
        s.stop()
        advanceTimeBy(1000)
        s.cancel()
        advanceUntilIdle()
        assertEquals(SessionState.Idle, s.state.value)
        assertTrue(editor.commits.isEmpty())
        assertEquals(DraftStatus.CANCELLED, onlyDraft().status)
    }

    @Test
    fun retry_fills_text_without_delivering() = runTest {
        serverUp = false
        val s = session()
        dictate(s, "ar")
        val kept = (s.state.value as SessionState.Kept).draft
        assertNull(kept.text)

        serverUp = true
        val retried = s.retry(kept)
        assertEquals("hello world", retried.text)
        assertEquals(DraftStatus.PENDING, retried.status)
        assertEquals(listOf(server, "ar", "NixOS, flake."), remoteCalls.single())
        assertTrue(editor.commits.isEmpty())
        assertEquals("hello world", drafts.pending().single().text)

        assertTrue(s.deliver(retried, editor))
        assertEquals(listOf("hello world "), editor.commits)
        assertTrue(drafts.pending().isEmpty())
        assertEquals(DraftStatus.DELIVERED, onlyDraft().status)
    }

    @Test
    fun retry_without_server_keeps_draft_and_records_error() = runTest {
        serverUp = false
        val s = session()
        dictate(s, "ar")
        val kept = (s.state.value as SessionState.Kept).draft
        val retried = s.retry(kept)
        assertNull(retried.text)
        assertEquals(DictationSession.NO_SERVER, retried.error)
        assertEquals(DraftStatus.PENDING, onlyDraft().status)
        assertFalse(s.deliver(retried, editor))
    }

    // A kept draft with text: the field changed while it was transcribing.
    private fun TestScope.keptWithText(s: DictationSession): Draft {
        s.start("en", editor)
        advanceUntilIdle()
        editor.token = "org.browser/7"
        s.stop()
        advanceUntilIdle()
        editor.token = "org.notes/42"
        return (s.state.value as SessionState.Kept).draft.also { assertEquals("hello world", it.text) }
    }

    @Test
    fun late_retry_after_deliver_leaves_it_delivered() = runTest {
        val s = session()
        val kept = keptWithText(s)
        remote = {
            delay(5000)
            "second take"
        }
        launch { s.retry(kept) }
        advanceTimeBy(1000)
        assertTrue(s.deliver(kept, editor))
        advanceUntilIdle()
        val d = onlyDraft()
        assertEquals(DraftStatus.DELIVERED, d.status)
        assertEquals("hello world", d.text)
        assertEquals(listOf("hello world "), editor.commits)
    }

    @Test
    fun late_retry_after_discard_leaves_it_cancelled() = runTest {
        serverUp = false
        val s = session()
        dictate(s, "ar")
        val kept = (s.state.value as SessionState.Kept).draft
        serverUp = true
        remote = {
            delay(5000)
            "hello world"
        }
        launch { s.retry(kept) }
        advanceTimeBy(1000)
        drafts.update(kept.copy(status = DraftStatus.CANCELLED)) // discarded in the app meanwhile
        advanceUntilIdle()
        val d = onlyDraft()
        assertEquals(DraftStatus.CANCELLED, d.status)
        assertNull(d.text)
    }

    @Test
    fun concurrent_retries_transcribe_once() = runTest {
        serverUp = false
        val s = session()
        dictate(s, "ar")
        val kept = (s.state.value as SessionState.Kept).draft
        serverUp = true
        remote = {
            delay(5000)
            "hello world"
        }
        launch { s.retry(kept) }
        launch { s.retry(kept) }
        advanceUntilIdle()
        assertEquals(1, remoteCalls.size)
        assertEquals("hello world", onlyDraft().text)
        assertEquals(DraftStatus.PENDING, onlyDraft().status)
    }

    @Test
    fun deliver_twice_types_once() = runTest {
        val s = session()
        val kept = keptWithText(s)
        assertTrue(s.deliver(kept, editor))
        assertFalse(s.deliver(kept, editor))
        assertEquals(listOf("hello world "), editor.commits)
    }

    @Test
    fun appends_single_space() = runTest {
        remote = { "  Hello NixOS.  \n" }
        dictate(session())
        assertEquals(listOf("Hello NixOS. "), editor.commits)
        assertEquals("Hello NixOS.", onlyDraft().text)
    }

    @Test
    fun empty_transcript_kept_as_nothing_heard() = runTest {
        remote = { " \n" }
        val s = session()
        dictate(s)
        assertEquals(DictationSession.NOTHING_HEARD, (s.state.value as SessionState.Kept).reason)
        assertTrue(editor.commits.isEmpty())
        assertEquals(DraftStatus.PENDING, onlyDraft().status)
    }

    // --- segments (with a VAD) ---

    // 1 s speech, 1 s silence, 1 s speech, 1 s silence, 0.5 s speech still going at stop.
    private fun speech(vararg runs: Pair<Double, Boolean>): ShortArray =
        runs.flatMap { (sec, voiced) -> List((sec * 16000).toInt()) { (if (voiced) 3000 else 0).toShort() } }.toShortArray()
    private val threeSegments = speech(1.0 to true, 1.0 to false, 1.0 to true, 1.0 to false, 0.5 to true)

    private fun segmented(samples: ShortArray = threeSegments, texts: List<String> = listOf("Hello there.", "how are you", "?")) {
        vad = { FakeVad() }
        audio.samples = samples
        var call = 0
        remote = { texts[call++ % texts.size] }
    }

    @Test
    fun segments_transcribed_while_recording_then_typed_at_once() = runTest {
        segmented()
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        // Two pauses heard: both segments transcribed before stop, each with the text before it.
        assertEquals(
            listOf(listOf(server, "en", "NixOS, flake."), listOf(server, "en", "NixOS, flake. Hello there.")),
            remoteCalls,
        )
        assertEquals(SessionState.Recording(Engine.Remote(server), 0), s.state.value)
        assertTrue(editor.commits.isEmpty()) // batch: nothing typed yet
        val d0 = onlyDraft()
        assertEquals(listOf("Hello there.", "how are you"), drafts.segments(d0).map { it.text })

        s.stop()
        advanceUntilIdle()
        assertEquals("NixOS, flake. Hello there. how are you", remoteCalls[2][2])
        assertEquals(SessionState.Done("Hello there. how are you?"), s.state.value)
        assertEquals(listOf("Hello there. how are you? "), editor.commits)
        assertTrue(editor.composed.isEmpty())
        val d = onlyDraft()
        assertEquals(DraftStatus.DELIVERED, d.status)
        assertEquals("Hello there. how are you?", d.text)
        assertEquals(server, d.engine)
        assertEquals(3, drafts.segments(d).size)
        assertEquals(threeSegments.size, WavFiles.readSamples(d.audio).size) // the whole recording, as before
        assertFalse(java.io.File(d.dir, "segment.wav").exists())
    }

    @Test
    fun recording_shows_a_segment_being_transcribed() = runTest {
        segmented()
        remote = {
            delay(5000)
            "Hello there."
        }
        val s = session()
        s.start("en", editor)
        advanceTimeBy(100)
        assertEquals(SessionState.Recording(Engine.Remote(server), 0, transcribing = true), s.state.value)
        advanceUntilIdle()
        assertEquals(SessionState.Recording(Engine.Remote(server), 0, transcribing = false), s.state.value)
        s.cancel()
    }

    @Test
    fun stream_mode_composes_as_it_grows_and_commits_at_stop() = runTest {
        profile = profile!!.copy(mode = MODE_STREAM)
        segmented()
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        assertEquals(listOf("Hello there.", "Hello there. how are you"), editor.composed)
        assertTrue(editor.commits.isEmpty())

        s.stop()
        advanceUntilIdle()
        assertEquals(listOf("Hello there. how are you? "), editor.commits) // replaces the composing text
        assertEquals("", editor.composing)
        assertEquals(DraftStatus.DELIVERED, onlyDraft().status)
    }

    @Test
    fun stream_mode_field_change_stops_composing_and_keeps_pending() = runTest {
        profile = profile!!.copy(mode = MODE_STREAM)
        segmented()
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        editor.token = "org.browser/7"
        s.stop()
        advanceUntilIdle()
        assertEquals(DictationSession.FIELD_CHANGED, (s.state.value as SessionState.Kept).reason)
        // Nothing more into the new field (the keyboard cleared the old one when it was left).
        assertEquals(listOf("Hello there.", "Hello there. how are you"), editor.composed)
        assertTrue(editor.commits.isEmpty())
        val d = onlyDraft()
        assertEquals(DraftStatus.PENDING, d.status)
        assertEquals("Hello there. how are you?", d.text)
    }

    @Test
    fun stream_mode_cancel_removes_composing_text() = runTest {
        profile = profile!!.copy(mode = MODE_STREAM)
        segmented()
        val s = session()
        s.start("en", editor)
        advanceUntilIdle()
        s.cancel()
        advanceUntilIdle()
        assertEquals("", editor.composing)
        assertTrue(editor.commits.isEmpty())
        assertEquals(DraftStatus.CANCELLED, onlyDraft().status)
    }

    @Test
    fun stream_mode_failure_removes_composing_text_and_keeps_pending() = runTest {
        profile = profile!!.copy(mode = MODE_STREAM)
        segmented()
        var call = 0
        remote = { if (call++ == 0) "Hello there." else throw IOException("butternut: HTTP 500") }
        val s = session()
        s.start("ar", editor) // no on-phone model for Arabic
        s.stop()
        advanceUntilIdle()
        assertEquals(DictationSession.NO_SERVER, (s.state.value as SessionState.Kept).reason)
        assertEquals("", editor.composing)
        assertTrue(editor.commits.isEmpty())
        val d = onlyDraft()
        assertEquals(DraftStatus.PENDING, d.status)
        assertNull(d.text) // partial: a retry transcribes the whole recording
        assertEquals(2, remoteCalls.size) // the third segment is not tried
    }

    @Test
    fun segment_remote_fails_on_phone_model_takes_the_rest() = runTest {
        segmented()
        remote = { throw IOException("butternut: HTTP 500") }
        val s = session()
        s.start("en", editor)
        s.stop()
        advanceUntilIdle()
        assertEquals(1, remoteCalls.size) // not again after it failed
        assertEquals(3, local.calls)
        assertEquals(SessionState.Done("local text local text local text"), s.state.value)
        assertEquals(DictationSession.LOCAL_ENGINE, onlyDraft().engine)
    }

    @Test
    fun silence_only_is_nothing_heard() = runTest {
        segmented(samples = speech(3.0 to false))
        val s = session()
        s.start("en", editor)
        s.stop()
        advanceUntilIdle()
        assertEquals(DictationSession.NOTHING_HEARD, (s.state.value as SessionState.Kept).reason)
        assertTrue(remoteCalls.isEmpty())
        assertEquals(DraftStatus.PENDING, onlyDraft().status)
    }

    @Test
    fun vad_failure_transcribes_the_whole_recording() = runTest {
        segmented()
        vad = { throw IllegalStateException("model missing") }
        remote = { wav -> "whole ${WavFiles.readSamples(wav).size}" }
        val s = session()
        s.start("en", editor)
        s.stop()
        advanceUntilIdle()
        assertEquals(SessionState.Done("whole ${threeSegments.size}"), s.state.value)
        assertEquals(listOf(listOf(server, "en", "NixOS, flake.")), remoteCalls)
    }
}
