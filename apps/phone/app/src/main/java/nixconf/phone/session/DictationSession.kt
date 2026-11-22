package nixconf.phone.session

import java.io.File
import java.io.IOException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import nixconf.phone.engine.Engine
import nixconf.phone.engine.RemoteTranscriber
import nixconf.phone.engine.chooseEngine
import nixconf.phone.profile.Profile

/** The microphone. stop() returns once the last samples are written to [start]'s writer. */
interface AudioSource {
    fun start(out: WavWriter)
    fun stop()
    val level: StateFlow<Float>
}

/** The on-phone model; transcribe() blocks (run off the main thread). */
interface LocalTranscriber {
    val ready: Boolean
    fun transcribe(wav: File): String
}

/** The focused field. token = package + field id of the focused editor, null when there is none. */
interface EditorTarget {
    val token: String?
    fun commit(text: String): Boolean
}

sealed interface SessionState {
    data object Idle : SessionState

    /** engine is null while the servers are still being probed. */
    data class Recording(val engine: Engine?, val startedMs: Long) : SessionState
    data class Transcribing(val engine: Engine) : SessionState
    data class Done(val text: String) : SessionState
    data class Kept(val draft: Draft, val reason: String) : SessionState
}

/**
 * One mic press to one text: records into a draft while the engine is chosen
 * (the probe also wakes the socket-activated server), transcribes on stop and
 * types the text only into the field the recording started in. Anything that
 * goes wrong leaves the draft PENDING with its audio (and text, if any).
 * Call from the main thread.
 */
class DictationSession(
    private val profile: () -> Profile?,
    private val drafts: DraftStore,
    private val audio: AudioSource,
    private val remote: RemoteTranscriber,
    private val local: LocalTranscriber,
    private val probe: suspend (String) -> Boolean,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutableState = MutableStateFlow<SessionState>(SessionState.Idle)
    val state: StateFlow<SessionState> = mutableState.asStateFlow()

    private class Current(
        val draft: Draft,
        val writer: WavWriter,
        val profile: Profile?,
        val target: EditorTarget,
        val token: String?,
    ) {
        lateinit var engine: Deferred<Engine>
        var job: Job? = null
    }

    // Read from IO threads too (activeDraftId, while listing drafts).
    @Volatile private var current: Current? = null

    // Drafts a retry is transcribing (main thread).
    private val retrying = mutableSetOf<String>()

    /** The draft being recorded or transcribed: not one to list as pending or retry. */
    val activeDraftId: String? get() = current?.draft?.id

    /** Starts recording; ignored while a session is recording or transcribing. */
    fun start(language: String, target: EditorTarget) {
        if (current != null) return
        val p = profile()
        val draft = drafts.create(language)
        val writer = WavWriter(draft.audio)
        val startedMs = clock()
        try {
            audio.start(writer)
        } catch (e: Exception) {
            closeQuietly(writer)
            save(draft.copy(status = DraftStatus.CANCELLED, error = e.message))
            throw e
        }
        val cur = Current(draft, writer, p, target, target.token)
        current = cur
        mutableState.value = SessionState.Recording(null, startedMs)
        cur.engine = scope.async {
            choose(p, language).also {
                if (current === cur && mutableState.value is SessionState.Recording) {
                    mutableState.value = SessionState.Recording(it, startedMs)
                }
            }
        }
    }

    /** Stops recording, then transcribes and delivers; a no-op unless recording. */
    fun stop() {
        val cur = current ?: return
        if (cur.job != null) return
        audio.stop()
        closeQuietly(cur.writer)
        cur.job = scope.launch { finish(cur) }
    }

    /** Discards the session: draft CANCELLED, nothing typed. */
    fun cancel() {
        val cur = current ?: return
        cur.engine.cancel()
        val job = cur.job
        if (job == null) {
            audio.stop()
            closeQuietly(cur.writer)
        } else {
            job.cancel()
        }
        save(cur.draft.copy(status = DraftStatus.CANCELLED))
        end(SessionState.Idle)
    }

    /**
     * Transcribes a kept draft again; its text is stored but it stays PENDING
     * until [deliver]ed. A no-op (returns [draft]) while that draft is being
     * recorded, transcribed or retried; if it was delivered or discarded in
     * the meantime, that state is kept and returned.
     */
    suspend fun retry(draft: Draft): Draft {
        if (draft.id == activeDraftId || !retrying.add(draft.id)) return draft
        try {
            val p = profile()
            val outcome = transcribe(draft.audio, draft.language, p, choose(p, draft.language))
            val now = onDisk(draft)
            if (now.status != DraftStatus.PENDING) return now
            val updated = if (outcome.text != null) {
                now.copy(engine = outcome.engine, text = outcome.text, error = null)
            } else {
                now.copy(error = outcome.error ?: outcome.reason)
            }
            save(updated)
            return updated
        } finally {
            retrying.remove(draft.id)
        }
    }

    /** Types a draft's text (plus a space) into [target]; DELIVERED if it went in. Only a still PENDING draft. */
    fun deliver(draft: Draft, target: EditorTarget): Boolean {
        val text = draft.text ?: return false
        if (onDisk(draft).status != DraftStatus.PENDING) return false
        if (!target.commit("$text ")) return false
        save(draft.copy(status = DraftStatus.DELIVERED))
        val state = mutableState.value
        if (state is SessionState.Kept && state.draft.id == draft.id) mutableState.value = SessionState.Done(text)
        return true
    }

    private suspend fun finish(cur: Current) {
        val engine = cur.engine.await()
        mutableState.value = SessionState.Transcribing(engine)
        val outcome = transcribe(cur.draft.audio, cur.draft.language, cur.profile, engine)
        val draft = cur.draft.copy(engine = outcome.engine, text = outcome.text, error = outcome.error ?: outcome.reason)
        val text = outcome.text
        if (text == null) {
            save(draft)
            end(SessionState.Kept(draft, outcome.reason!!))
            return
        }
        // Only into the field the recording started in: the user may have
        // switched app (or closed the keyboard) while it was transcribing.
        val token = cur.target.token
        if (token != null && token == cur.token && cur.target.commit("$text ")) {
            save(draft.copy(status = DraftStatus.DELIVERED))
            end(SessionState.Done(text))
        } else {
            save(draft)
            end(SessionState.Kept(draft, FIELD_CHANGED))
        }
    }

    // text: the trimmed, non-empty transcript; otherwise reason says why not
    // (and error what failed, if anything did).
    private class Outcome(val text: String?, val engine: String?, val reason: String?, val error: String? = null)

    // Remote first; if it fails mid-session (server busy, network gone, 500,
    // timeout) the on-phone model takes over when it can.
    private suspend fun transcribe(wav: File, language: String, p: Profile?, engine: Engine): Outcome {
        var error: String? = null
        if (engine is Engine.Remote) {
            try {
                return outcome(remote.transcribe(engine.url, wav, language, p?.prompt.orEmpty()), engine.url)
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                error = e.message
            }
        }
        if (engine == Engine.Unavailable || !localEligible(p, language)) return Outcome(null, null, NO_SERVER, error)
        return try {
            outcome(withContext(io) { local.transcribe(wav) }, LOCAL_ENGINE)
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            Outcome(null, LOCAL_ENGINE, LOCAL_FAILED, e.message)
        }
    }

    private fun outcome(raw: String, engine: String): Outcome {
        val text = raw.trim()
        return if (text.isEmpty()) Outcome(null, engine, NOTHING_HEARD) else Outcome(text, engine, null)
    }

    private suspend fun choose(p: Profile?, language: String): Engine =
        chooseEngine(p?.servers.orEmpty(), language, local.ready, p?.localModel?.language.orEmpty(), probe)

    private fun localEligible(p: Profile?, language: String) = local.ready && p?.localModel?.language == language

    private fun end(state: SessionState) {
        current = null
        mutableState.value = state
    }

    // The draft as on disk now: it may have been delivered or discarded
    // since [draft] was read. Gone from disk: the copy given.
    private fun onDisk(draft: Draft): Draft = drafts.load(draft.id) ?: draft

    // The draft stays on disk as last written (at worst PENDING without text):
    // never crash the keyboard over a meta.json write.
    private fun save(draft: Draft) {
        try {
            drafts.update(draft)
        } catch (e: IOException) {
            // Kept in memory (state Kept) for this session.
        }
    }

    private fun closeQuietly(writer: WavWriter) = try {
        writer.close()
    } catch (e: IOException) {
        // The samples are flushed; DraftStore.load repairs the header.
    }

    companion object {
        const val LOCAL_ENGINE = "local"
        const val FIELD_CHANGED = "field changed"
        const val NO_SERVER = "no server reachable"
        const val NOTHING_HEARD = "nothing heard"
        const val LOCAL_FAILED = "on-phone transcription failed"
    }
}
