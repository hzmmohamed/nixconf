package nixconf.phone.session

import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
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
import nixconf.phone.audio.WavFiles
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import nixconf.phone.drafts.SegmentText
import nixconf.phone.engine.Engine
import nixconf.phone.engine.RemoteTranscriber
import nixconf.phone.engine.chooseEngine
import nixconf.phone.profile.MODE_STREAM
import nixconf.phone.profile.Profile
import nixconf.phone.segment.Segment
import nixconf.phone.segment.SpeechProbability
import nixconf.phone.segment.clean
import nixconf.phone.segment.joinTexts

/**
 * The microphone. Every read goes to [start]'s writer, then to tap (if any);
 * stop() returns once the last samples went to both.
 */
interface AudioSource {
    fun start(out: WavWriter, tap: ((ShortArray, Int) -> Unit)? = null)
    fun stop()
    val level: StateFlow<Float>
}

/** The on-phone model; transcribe() blocks (run off the main thread). */
interface LocalTranscriber {
    val ready: Boolean
    fun transcribe(wav: File): String
}

/**
 * The focused field. token = package + field id of the focused editor, null
 * when there is none. compose() shows text as composing text (replacing what
 * it showed before; "" removes it); commit() replaces the composing text, if any.
 */
interface EditorTarget {
    val token: String?
    fun commit(text: String): Boolean
    fun compose(text: String): Boolean

    /** Incognito field (no personalized learning): a draft typed into it is deleted, not kept as DELIVERED. */
    val incognito: Boolean get() = false

    /** Composing text suits the field (stream mode): not number, date or incognito fields. */
    val composable: Boolean get() = true
}

/** What [DictationSession.deliver] did; BUSY: a session is running (its text must not be mixed in). */
enum class Delivery { TYPED, NO_TEXT, GONE, NO_FIELD, BUSY }

/** start() failed: the draft could not be written ([storage]) or the microphone would not open. */
class StartException(val storage: Boolean, cause: Exception) : Exception(cause.message, cause)

sealed interface SessionState {
    data object Idle : SessionState

    /**
     * engine is null while the servers are still being probed (Local once the
     * phone took over); transcribing: a segment, while recording goes on.
     */
    data class Recording(val engine: Engine?, val startedMs: Long, val transcribing: Boolean = false) : SessionState

    /**
     * Stopped, the text not there yet: engine null while the probe still runs;
     * segmented, [done] of the [total] segments cut so far are transcribed
     * (total 0: the recording is transcribed as a whole).
     */
    data class Finishing(val engine: Engine?, val done: Int = 0, val total: Int = 0) : SessionState
    data class Done(val text: String) : SessionState
    data class Kept(val draft: Draft, val reason: String) : SessionState
}

/**
 * One mic press to one text: records into a draft while the engine is chosen
 * (the probe also wakes the socket-activated server) and types the text only
 * into the field the recording started in. With a [vad], the recording is cut
 * at its pauses (as on the laptops) and each segment is transcribed while
 * recording goes on, the text so far in the Whisper prompt; stop waits for
 * the last one. Without (or if the VAD fails), the whole recording is
 * transcribed at stop. Mode (profile): batch types the text at stop; stream
 * shows it as composing text as it grows and commits it at stop. Anything
 * that goes wrong leaves the draft PENDING with its audio (and text, if any).
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
    private val vad: (() -> SpeechProbability)? = null,
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
        val feed: SegmentFeed?,
        val startedMs: Long,
    ) {
        lateinit var chosen: Deferred<Engine>
        var job: Job? = null

        // The segments' outcome; null: the VAD failed, transcribe the whole file.
        var segmented: Deferred<Outcome?>? = null

        // Composing text is showing in the field (stream mode).
        var composed = false
        val stream = profile?.mode == MODE_STREAM && target.composable

        // What the state shows: the engine (null while probing, Local once the
        // phone took over), stop pressed, a segment being transcribed, and how
        // many are done (wholeFile: the VAD failed, no segments to count).
        var engine: Engine? = null
        var stopped = false
        var transcribing = false
        var done = 0
        var wholeFile = false

        fun inField(): Boolean = target.token.let { it != null && it == token }
    }

    // Read from IO threads too (activeDraftId, while listing drafts).
    @Volatile private var current: Current? = null

    // Drafts a retry is transcribing (main thread).
    private val retrying = mutableSetOf<String>()

    /** The draft being recorded or transcribed: not one to list as pending or retry. */
    val activeDraftId: String? get() = current?.draft?.id

    /**
     * Starts recording; ignored while a session is recording or transcribing.
     * Throws [StartException] if the draft or the microphone cannot be opened.
     */
    fun start(language: String, target: EditorTarget) {
        if (current != null) return
        val p = profile()
        val draft = try {
            drafts.create(language)
        } catch (e: IOException) {
            throw StartException(storage = true, e)
        }
        val writer = try {
            WavWriter(draft.audio)
        } catch (e: IOException) {
            save(draft.copy(status = DraftStatus.CANCELLED, error = e.message))
            throw StartException(storage = true, e)
        }
        val startedMs = clock()
        val feed = vad?.let { SegmentFeed(it, p?.pauseMs ?: PAUSE_MS, p?.maxSegmentSec ?: MAX_SEGMENT_SEC, scope, io) }
        try {
            audio.start(writer, feed?.let { it::tap })
        } catch (e: Exception) {
            feed?.cancel()
            closeQuietly(writer)
            save(draft.copy(status = DraftStatus.CANCELLED, error = e.message))
            throw StartException(storage = false, e)
        }
        val cur = Current(draft, writer, p, target, target.token, feed, startedMs)
        current = cur
        publish(cur)
        cur.chosen = scope.async {
            choose(p, language).also {
                cur.engine = it
                publish(cur)
            }
        }
        if (feed != null) cur.segmented = scope.async { transcribeSegments(cur, feed) }
    }

    /**
     * Stops recording, then transcribes and delivers; a no-op unless recording.
     * The state turns Finishing at once: the probe may still take a while.
     */
    fun stop() {
        val cur = current ?: return
        if (cur.stopped) return
        cur.stopped = true
        audio.stop()
        cur.feed?.end()
        closeQuietly(cur.writer)
        publish(cur)
        cur.job = scope.launch { finish(cur) }
    }

    /** Discards the session: draft CANCELLED, nothing typed. */
    fun cancel() {
        val cur = current ?: return
        cur.chosen.cancel()
        cur.segmented?.cancel()
        cur.feed?.cancel()
        cur.job?.cancel()
        if (!cur.stopped) {
            audio.stop()
            closeQuietly(cur.writer)
        }
        dropComposing(cur)
        save(cur.draft.copy(status = DraftStatus.CANCELLED))
        end(SessionState.Idle)
    }

    /**
     * Transcribes a kept draft again; its text is stored (and shown, if it is
     * the Kept one) but it stays PENDING until [deliver]ed. A no-op (returns
     * [draft]) while that draft is being recorded, transcribed or retried; if
     * it was delivered or discarded in the meantime, that state is kept and
     * returned.
     */
    suspend fun retry(draft: Draft): Draft {
        if (draft.id == activeDraftId || !retrying.add(draft.id)) return draft
        try {
            val p = profile()
            val outcome = transcribe(draft.audio, draft.language, p, choose(p, draft.language), p?.prompt.orEmpty())
            val now = onDisk(draft)
            if (now.status != DraftStatus.PENDING) return now
            val updated = if (outcome.text != null) {
                now.copy(engine = outcome.engine, text = outcome.text, error = null)
            } else {
                now.copy(error = outcome.error ?: outcome.reason)
            }
            save(updated)
            // The panel offers the draft it shows as it is now (with its text: Insert here).
            val state = mutableState.value
            if (state is SessionState.Kept && state.draft.id == draft.id) mutableState.value = state.copy(draft = updated)
            return updated
        } finally {
            retrying.remove(draft.id)
        }
    }

    /**
     * Types a draft's text (plus a space) into [target]; DELIVERED if it went
     * in (and the state shows it Done). Only a still PENDING draft (else GONE:
     * delivered or discarded since), and not while a session runs.
     */
    fun deliver(draft: Draft, target: EditorTarget): Delivery {
        val text = draft.text ?: return Delivery.NO_TEXT
        if (current != null) return Delivery.BUSY
        if (onDisk(draft).status != DraftStatus.PENDING) return Delivery.GONE
        if (!target.commit("$text ")) return Delivery.NO_FIELD
        delivered(draft, target)
        mutableState.value = SessionState.Done(text)
        return Delivery.TYPED
    }

    /**
     * A new field: the last result was not typed there, so the panel goes back
     * to Idle, except for a draft still pending with its text (offered to
     * insert here). Nothing changes while a session runs.
     */
    fun newInput() {
        if (current != null) return
        val state = mutableState.value
        if (state is SessionState.Kept && state.draft.text != null && onDisk(state.draft).status == DraftStatus.PENDING) return
        mutableState.value = SessionState.Idle
    }

    private suspend fun finish(cur: Current) {
        val engine = cur.chosen.await()
        val outcome = cur.segmented?.await() ?: run {
            cur.wholeFile = true
            publish(cur)
            transcribe(cur.draft.audio, cur.draft.language, cur.profile, engine, cur.profile?.prompt.orEmpty()) {
                onPhone(cur)
            }
        }
        val draft = cur.draft.copy(engine = outcome.engine, text = outcome.text, error = outcome.error ?: outcome.reason)
        val text = outcome.text
        if (text == null) {
            dropComposing(cur)
            save(draft)
            end(SessionState.Kept(draft, outcome.reason!!))
            return
        }
        // Only into the field the recording started in: the user may have
        // switched app (or closed the keyboard) while it was transcribing.
        if (cur.inField() && cur.target.commit("$text ")) {
            cur.composed = false
            delivered(draft, cur.target)
            end(SessionState.Done(text))
        } else {
            dropComposing(cur)
            save(draft)
            end(SessionState.Kept(draft, FIELD_CHANGED))
        }
    }

    /**
     * Transcribes the feed's segments in order as they close (one at a time,
     * so each prompt has all the text before it); each text lands in the
     * draft's segments.jsonl and, in stream mode, in the field. A segment
     * that fails ends the work (the rest is skipped: the draft is kept for
     * a whole-file retry). Null if the feed failed.
     */
    private suspend fun transcribeSegments(cur: Current, feed: SegmentFeed): Outcome? {
        var engine = cur.chosen.await()
        val texts = mutableListOf<String>()
        var used: String? = null
        var i = 0
        val wav = File(cur.draft.dir, "segment.wav")
        try {
            for (segment in feed.segments) {
                val index = i++
                cur.transcribing = true
                publish(cur)
                val prompt = "${cur.profile?.prompt.orEmpty()} ${joinTexts(texts).takeLast(PROMPT_CONTEXT)}".trim()
                withContext(io) { WavFiles.write(wav, segment.samples) }
                val outcome = transcribe(wav, cur.draft.language, cur.profile, engine, prompt) { onPhone(cur) }
                cur.transcribing = false
                val failed = outcome.text == null && outcome.reason != NOTHING_HEARD
                if (!failed) cur.done++
                publish(cur)
                if (failed) {
                    feed.cancel()
                    return outcome
                }
                // The server failed and the on-phone model took over: it keeps the session.
                if (outcome.engine == LOCAL_ENGINE) engine = Engine.Local
                used = outcome.engine
                val text = outcome.text ?: continue
                texts += text
                record(cur, index, segment, text, outcome.engine)
                if (cur.stream && cur.inField()) cur.composed = cur.target.compose(joinTexts(texts)) || cur.composed
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return null // the VAD failed (or the segment file could not be written)
        } finally {
            wav.delete()
        }
        if (texts.isEmpty()) return Outcome(null, used, NOTHING_HEARD)
        return Outcome(joinTexts(texts), used, null)
    }

    private suspend fun record(cur: Current, i: Int, segment: Segment, text: String, engine: String?) {
        try {
            withContext(io) { drafts.addSegment(cur.draft, SegmentText(i, segment.start, segment.end, text, engine)) }
        } catch (e: IOException) {
            // The text still goes into the session's result.
        }
    }

    // Composing text left in the field the session started in is removed
    // (a field the user left already lost it: DictationIme.onFinishInput).
    private fun dropComposing(cur: Current) {
        if (cur.composed && cur.inField()) cur.target.compose("")
        cur.composed = false
    }

    // The state of [cur] as it is now; a no-op once it ended.
    private fun publish(cur: Current) {
        if (current !== cur) return
        mutableState.value = if (!cur.stopped) {
            SessionState.Recording(cur.engine, cur.startedMs, cur.transcribing)
        } else {
            val total = if (cur.wholeFile) 0 else cur.feed?.closed ?: 0
            SessionState.Finishing(cur.engine, if (total == 0) 0 else cur.done, total)
        }
    }

    // The server failed and the on-phone model takes over: shown for the rest of the session.
    private fun onPhone(cur: Current) {
        cur.engine = Engine.Local
        publish(cur)
    }

    // An incognito field keeps nothing of what was typed into it: the draft
    // (audio, text, segments) goes once delivered. Marked DELIVERED first, so
    // a delete that fails leaves a draft pruned as usual.
    private fun delivered(draft: Draft, target: EditorTarget) {
        save(draft.copy(status = DraftStatus.DELIVERED))
        if (target.incognito) drafts.delete(draft)
    }

    // text: the cleaned, non-empty transcript; otherwise reason says why not
    // (and error what failed, if anything did).
    private class Outcome(val text: String?, val engine: String?, val reason: String?, val error: String? = null)

    // Remote first; if it fails mid-session (server busy, network gone, 500,
    // timeout) the on-phone model takes over when it can (onLocal first).
    private suspend fun transcribe(
        wav: File,
        language: String,
        p: Profile?,
        engine: Engine,
        prompt: String,
        onLocal: () -> Unit = {},
    ): Outcome {
        var error: String? = null
        if (engine is Engine.Remote) {
            try {
                return outcome(remote.transcribe(engine.url, wav, language, prompt), engine.url)
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                error = e.message
            }
        }
        if (engine == Engine.Unavailable || !localEligible(p, language)) return Outcome(null, null, NO_SERVER, error)
        onLocal()
        return try {
            outcome(withContext(io) { local.transcribe(wav) }, LOCAL_ENGINE)
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            Outcome(null, LOCAL_ENGINE, LOCAL_FAILED, e.message)
        }
    }

    private fun outcome(raw: String, engine: String): Outcome {
        val text = clean(raw)
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

        // Defaults when there is no profile (as the profile's).
        private const val PAUSE_MS = 550
        private const val MAX_SEGMENT_SEC = 25

        // Characters of the text so far that go into a segment's prompt.
        private const val PROMPT_CONTEXT = 200
    }
}
