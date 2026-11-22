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
import nixconf.phone.profile.Profile
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

    private class FakeAudio : AudioSource {
        override val level = MutableStateFlow(0f)
        var recording = false
        override fun start(out: WavWriter) {
            recording = true
            out.write(ShortArray(1600) { 100 }, 1600)
        }
        override fun stop() {
            recording = false
        }
    }
    private val audio = FakeAudio()

    private class FakeEditor(override var token: String?) : EditorTarget {
        val commits = mutableListOf<String>()
        override fun commit(text: String): Boolean {
            commits += text
            return true
        }
    }
    private val editor = FakeEditor("org.notes/42")

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
}
