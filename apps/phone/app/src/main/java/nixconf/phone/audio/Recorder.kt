package nixconf.phone.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import java.io.IOException
import kotlin.math.sqrt
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import nixconf.phone.session.AudioSource

// The microphone: 16 kHz mono PCM16 from AudioRecord (VOICE_RECOGNITION, the
// source tuned for speech), written to the draft's WAV on a thread of its own
// and fsynced every 2 s, so a killed app loses at most that much.
// The caller holds RECORD_AUDIO (the keyboard checks before starting).
class Recorder(private val sampleRate: Int = 16000) : AudioSource {
    private val mutableLevel = MutableStateFlow(0f)
    override val level: StateFlow<Float> = mutableLevel.asStateFlow()

    private var record: AudioRecord? = null
    private var thread: Thread? = null

    @Volatile private var running = false

    @SuppressLint("MissingPermission")
    override fun start(out: WavWriter) {
        check(record == null) { "already recording" }
        val min = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) throw IOException("microphone does not support $sampleRate Hz mono")
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(min, sampleRate), // ≥ 0.5 s of slack
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IOException("microphone unavailable")
        }
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            throw IOException("microphone busy")
        }
        record = rec
        running = true
        thread = Thread({ loop(rec, out) }, "recorder").apply { start() }
    }

    override fun stop() {
        val rec = record ?: return
        running = false
        rec.stop()
        thread?.join()
        rec.release()
        record = null
        thread = null
        mutableLevel.value = 0f
    }

    private fun loop(rec: AudioRecord, out: WavWriter) {
        val buf = ShortArray(sampleRate / 10)
        var lastFlush = SystemClock.elapsedRealtime()
        try {
            while (running) {
                val n = rec.read(buf, 0, buf.size)
                if (n < 0) break
                if (n == 0) continue
                out.write(buf, n)
                mutableLevel.value = level(buf, n)
                val now = SystemClock.elapsedRealtime()
                if (now - lastFlush >= FLUSH_MS) {
                    out.flush()
                    lastFlush = now
                }
            }
            // What stop() let through (read() returns what is buffered).
            out.flush()
        } catch (e: IOException) {
            // Disk full or the like: what was flushed stays in the draft.
        }
    }

    // RMS as 0..1, scaled so normal speech fills most of the bar.
    private fun level(buf: ShortArray, n: Int): Float {
        var sum = 0.0
        for (i in 0 until n) sum += buf[i].toDouble() * buf[i]
        return (sqrt(sum / n) / 32768 * 6).toFloat().coerceIn(0f, 1f)
    }

    private companion object {
        const val FLUSH_MS = 2000L
    }
}
