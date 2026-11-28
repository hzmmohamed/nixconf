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

/**
 * Records one diary entry. Implements [PcmSink]: it is what [AudioSource.start]
 * writes into, so [write] and [flush] run on the recorder thread while [start]
 * and [stop] run on the main thread - [lock] guards the encoder and the
 * not-yet-sealed byte buffer, the only state both sides touch.
 *
 * [write] only encodes and buffers; it never touches the store, so it never
 * fails. [flush] (called by [audio] roughly every [flushMs], and once more
 * at [stop]) seals whatever is buffered as one audio frame - skipped if
 * nothing is buffered. The encoder's codec-config (Opus CSD, base64) is
 * written to the entry's meta via [EntryStore.OpenEntry.update] as soon as
 * the encoder produces it, at or before the first frame.
 *
 * On a storage failure (appendAudio throwing IOException): the audio source
 * is stopped, the entry is finished with the duration captured so far
 * (best-effort - a second failure there is ignored), and the state becomes
 * [RecState.Failed] with a fixed, user-facing message. Whatever was already
 * sealed (earlier frames) stays on disk and readable.
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
            mutableState.value = RecState.Failed(null, "Storage is full: the recording was saved up to here")
            return
        }
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
            val durationMs = samplesWritten * 1000 / SAMPLE_RATE
            try {
                openEntry.finish(durationMs)
            } catch (ignored: IOException) {
                // Best-effort: the start failure itself is what matters.
            }
            synchronized(lock) { open = null; activeEncoder = null }
            enc.close()
            mutableState.value = RecState.Failed(openEntry.entry.id, e.message ?: "Could not start recording")
        }
    }

    override fun write(samples: ShortArray, n: Int) {
        val (entry, enc) = synchronized(lock) {
            val e = open ?: return
            val c = activeEncoder ?: return
            e to c
        }
        val packets = enc.encode(samples, n)
        synchronized(lock) {
            // start() may have been superseded (stopped/failed) while encode() ran.
            if (open !== entry) return
            samplesWritten += n
            maybeCaptureConfig(entry, enc)
            for (p in packets) appendToBuffer(enc.codec, p)
        }
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
            fail(entry)
        }
    }

    /** Stops the microphone, seals the last frame (encoder drain + whatever is buffered) and finishes the entry. */
    fun stop() {
        val entry = synchronized(lock) { open } ?: return
        audio.stop()
        val enc = synchronized(lock) { activeEncoder } ?: return
        try {
            val packets = enc.drain()
            synchronized(lock) {
                maybeCaptureConfig(entry, enc)
                for (p in packets) appendToBuffer(enc.codec, p)
            }
            val bytes = synchronized(lock) {
                if (buffer.size() == 0) null else buffer.toByteArray().also { buffer = ByteArrayOutputStream() }
            }
            bytes?.let { entry.appendAudio(it) }
            val durationMs = samplesWritten * 1000 / SAMPLE_RATE
            entry.finish(durationMs)
            enc.close()
            synchronized(lock) { open = null; activeEncoder = null }
            mutableState.value = RecState.Saved(entry.entry.id, durationMs)
        } catch (e: IOException) {
            enc.close()
            fail(entry)
        }
    }

    // Must be called holding [lock].
    private fun maybeCaptureConfig(entry: EntryStore.OpenEntry, enc: AudioEncoder) {
        if (configWritten) return
        val config = enc.config ?: return
        configWritten = true
        entry.update { it.copy(codecConfig = Base64.getEncoder().encodeToString(config)) }
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

    private fun fail(entry: EntryStore.OpenEntry) {
        audio.stop()
        val durationMs = samplesWritten * 1000 / SAMPLE_RATE
        try {
            entry.finish(durationMs)
        } catch (ignored: IOException) {
            // Best-effort: the original failure is what the state reports.
        }
        synchronized(lock) { open = null; activeEncoder = null }
        mutableState.value = RecState.Failed(entry.entry.id, "Storage is full: the recording was saved up to here")
    }
}
