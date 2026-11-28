package nixconf.phone.diary

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import nixconf.phone.audio.PcmSink
import nixconf.phone.session.AudioSource

/** Recording state as the diary UI sees it. */
sealed interface RecState {
    data object Idle : RecState
    data class Recording(val entryId: String, val startedAt: Long, val level: Float) : RecState
    data class Saved(val entryId: String, val durationMs: Long) : RecState
    data class Failed(val entryId: String?, val message: String) : RecState
}

private const val SAMPLE_RATE = 16000

// User-facing failure copy: fixed text, never the underlying exception's message (that may
// leak paths or otherwise not be meant for a person to read). Storage failures (appendAudio,
// or the meta rewrite that writes codecConfig - both are EntryStore I/O) get the "saved up to
// here" copy; an encoder throwing (MediaCodec dying) gets a different one, since nothing about
// disk space is at fault there.
private const val STORAGE_FAILED_MESSAGE = "Storage is full: the recording was saved up to here"
private const val ENCODER_FAILED_MESSAGE = "Recording stopped: the audio encoder failed"
private const val START_FAILED_MESSAGE = "Could not start a diary entry"
private const val MIC_FAILED_MESSAGE = "Could not start the microphone"

/**
 * Records one diary entry. Implements [PcmSink]: it is what [AudioSource.start]
 * writes into, so [write] and [flush] run on the recorder thread while [start]
 * and [stop] run on the main thread - [lock] guards the encoder and the
 * not-yet-sealed byte buffer, the only state both sides touch.
 *
 * [write] only encodes and buffers; it never touches the store on its own, but the
 * encoder it calls can still throw (MediaCodec dying) - handled the same way as a
 * storage failure, just with a different message. [flush] (called by [audio] roughly
 * every [flushMs], and once more at [stop]) seals whatever is buffered as one audio
 * frame - skipped if nothing is buffered. The encoder's codec-config (Opus CSD) is
 * written to the entry's meta, as its raw OpusHead ([opusHeadOf]) base64-encoded, as
 * soon as the encoder has produced one - at or before the first frame.
 *
 * On any failure (appendAudio/the meta rewrite throwing IOException, or the encoder
 * throwing): the audio source is stopped, the encoder is closed, the entry is finished
 * with the duration captured so far (best-effort - a second failure there is ignored),
 * and the state becomes [RecState.Failed] with a fixed, user-facing message. Whatever
 * was already sealed (earlier frames) stays on disk and readable. [fail] is idempotent
 * (and the only place that closes the encoder on a failure path), so it is safe to call
 * from more than one of [write]/[flush]/[stop] without double-closing or double-reporting.
 */
class DiaryRecording(
    private val store: EntryStore,
    private val audio: AudioSource,
    private val encoder: () -> AudioEncoder,
    private val zone: () -> String,
    private val flushMs: Long = 2000,
    private val now: () -> Long,
) : PcmSink {
    private val mutableState = MutableStateFlow<RecState>(RecState.Idle)
    val state: StateFlow<RecState> = mutableState.asStateFlow()

    /** [flushMs] is the cadence the audio source is expected to call [flush] at; kept for callers/tests to read. */
    val flushIntervalMs: Long get() = flushMs

    private val lock = Any()
    private var open: EntryStore.OpenEntry? = null
    private var activeEncoder: AudioEncoder? = null
    private var buffer = ByteArrayOutputStream()
    private var samplesWritten = 0L
    private var configWritten = false

    /** Starts a new entry and the microphone; ignored while already recording. */
    fun start() {
        if (state.value is RecState.Recording) return
        val enc = encoder()
        val openEntry = try {
            store.create(Kind.spoken, enc.codec, zone())
        } catch (e: IOException) {
            enc.close()
            mutableState.value = RecState.Failed(null, START_FAILED_MESSAGE)
            return
        }
        DiaryLog.i("entry ${openEntry.entry.id}: codec ${enc.codec}")
        synchronized(lock) {
            open = openEntry
            activeEncoder = enc
            buffer = ByteArrayOutputStream()
            samplesWritten = 0L
            configWritten = false
        }
        mutableState.value = RecState.Recording(openEntry.entry.id, now(), 0f)
        try {
            audio.start(this)
        } catch (e: Exception) {
            synchronized(lock) { open = null; activeEncoder = null }
            try {
                openEntry.finish(0)
            } catch (ignored: IOException) {
                // Best-effort: the start failure itself is what matters.
            }
            enc.close()
            mutableState.value = RecState.Failed(openEntry.entry.id, MIC_FAILED_MESSAGE)
        }
    }

    override fun write(samples: ShortArray, n: Int) {
        val (entry, enc) = synchronized(lock) {
            val e = open ?: return
            val c = activeEncoder ?: return
            e to c
        }
        val packets = try {
            enc.encode(samples, n)
        } catch (e: IOException) {
            fail(entry, ENCODER_FAILED_MESSAGE)
            return
        } catch (e: RuntimeException) {
            fail(entry, ENCODER_FAILED_MESSAGE)
            return
        }
        val config = synchronized(lock) {
            if (open !== entry) return
            samplesWritten += n
            for (p in packets) appendToBuffer(enc.codec, p)
            pendingConfig(enc)
        }
        if (config != null) writeConfig(entry, config)
    }

    override fun flush() {
        val entry = synchronized(lock) { open } ?: return
        val bytes = synchronized(lock) {
            if (buffer.size() == 0) return
            buffer.toByteArray().also { buffer = ByteArrayOutputStream() }
        }
        try {
            entry.appendAudio(bytes)
        } catch (e: IOException) {
            fail(entry, STORAGE_FAILED_MESSAGE)
        }
    }

    /** Stops the microphone, seals the last frame (encoder drain + whatever is buffered) and finishes the entry. */
    fun stop() {
        val entry = synchronized(lock) { open } ?: return
        audio.stop()
        val enc = synchronized(lock) { activeEncoder } ?: return
        val packets = try {
            enc.drain()
        } catch (e: IOException) {
            fail(entry, ENCODER_FAILED_MESSAGE)
            return
        } catch (e: RuntimeException) {
            fail(entry, ENCODER_FAILED_MESSAGE)
            return
        }
        val config = synchronized(lock) {
            if (open !== entry) return
            for (p in packets) appendToBuffer(enc.codec, p)
            pendingConfig(enc)
        }
        if (config != null && !writeConfig(entry, config)) return // writeConfig already failed us
        val bytes = synchronized(lock) {
            if (open !== entry) return
            if (buffer.size() == 0) null else buffer.toByteArray().also { buffer = ByteArrayOutputStream() }
        }
        try {
            bytes?.let { entry.appendAudio(it) }
            val durationMs = samplesWritten * 1000 / SAMPLE_RATE
            entry.finish(durationMs)
            synchronized(lock) { open = null; activeEncoder = null }
            enc.close()
            mutableState.value = RecState.Saved(entry.entry.id, durationMs)
        } catch (e: IOException) {
            fail(entry, STORAGE_FAILED_MESSAGE)
        }
    }

    // Must be called holding [lock]. The encoder's config, if it has produced one and
    // [configWritten] is still false - null otherwise (nothing yet, or already handled).
    private fun pendingConfig(enc: AudioEncoder): ByteArray? {
        if (configWritten) return null
        return enc.config
    }

    // Must be called holding [lock]. Opus packets are length-prefixed (u16 BE) so the frame can hold several;
    // PCM packets are raw bytes, concatenated directly (see the on-disk audio frame format).
    private fun appendToBuffer(codec: Codec, packet: ByteArray) {
        if (codec == Codec.opus) {
            buffer.write((packet.size ushr 8) and 0xFF)
            buffer.write(packet.size and 0xFF)
        }
        buffer.write(packet)
    }

    // Writes [rawConfig]'s OpusHead (see opusHeadOf) to the entry's meta, outside [lock]
    // (a meta rewrite, like appendAudio, is storage I/O - never done while holding it), and
    // marks configWritten on success so later calls stop checking. An unrecognised config
    // (opusHeadOf returns null) still marks configWritten - there is nothing more sensible to
    // try for this encoder - and logs a warning instead of storing bytes a reader might
    // mistake for a real OpusHead. False on a failure, which already called [fail] - storage
    // for an IOException (a real disk failure), the encoder copy for anything else (a crash
    // writing meta is not a disk-full story, but it is not a storage one either).
    private fun writeConfig(entry: EntryStore.OpenEntry, rawConfig: ByteArray): Boolean {
        val head = opusHeadOf(rawConfig)
        if (head == null) {
            DiaryLog.w("entry ${entry.entry.id}: unrecognised opus codec-config (${rawConfig.size} bytes), storing none")
            synchronized(lock) { configWritten = true }
            return true
        }
        return try {
            entry.update { it.copy(codecConfig = Base64.getEncoder().encodeToString(head)) }
            synchronized(lock) { configWritten = true }
            true
        } catch (e: IOException) {
            fail(entry, STORAGE_FAILED_MESSAGE)
            false
        } catch (e: RuntimeException) {
            fail(entry, ENCODER_FAILED_MESSAGE)
            false
        }
    }

    // Idempotent: a second call for an [entry] already handled (open no longer points at
    // it) does nothing, so write()/flush()/stop() can each reach a failure for the same
    // recording without double-closing the encoder or double-reporting the state. The state
    // is set to Failed *before* closing the encoder: a second failure while closing (the
    // encoder is already in a bad enough state to have failed once) must not stop the first
    // one from ever being reported, and must not escape to whichever thread called [fail]
    // (the recorder thread, for a failure from write()/flush()).
    private fun fail(entry: EntryStore.OpenEntry, message: String) {
        val enc = synchronized(lock) {
            if (open !== entry) return
            val e = activeEncoder
            open = null
            activeEncoder = null
            e
        }
        audio.stop()
        val durationMs = samplesWritten * 1000 / SAMPLE_RATE
        try {
            entry.finish(durationMs)
        } catch (ignored: IOException) {
            // Best-effort: the original failure is what the state reports.
        }
        mutableState.value = RecState.Failed(entry.entry.id, message)
        try {
            enc?.close()
        } catch (e: RuntimeException) {
            DiaryLog.w("entry ${entry.entry.id}: closing the encoder after a failure also failed: ${e.javaClass.simpleName}")
        }
    }
}
