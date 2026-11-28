package nixconf.phone.diary

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

// What DiaryRecording feeds PCM16 through before sealing it. [config] is
// the codec-specific data a reader needs before any packet makes sense
// (Opus: OpusHead/pre-skip/seek-preroll as MediaCodec emits it; PCM: none).
// Encoded packets are returned in call order; the caller frames/concatenates
// them per the on-disk format (see DiaryRecording).
interface AudioEncoder {
    val codec: Codec
    val config: ByteArray?
    fun encode(samples: ShortArray, n: Int): List<ByteArray>
    fun drain(): List<ByteArray>
    fun close()
}

/** No encoding: PCM16 little-endian passthrough. The fallback, and what JVM tests use (MediaCodec is device-only). */
class PcmPassthrough : AudioEncoder {
    override val codec = Codec.pcm_s16le
    override val config: ByteArray? = null

    override fun encode(samples: ShortArray, n: Int): List<ByteArray> {
        val bytes = ByteArray(n * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(samples, 0, n)
        return listOf(bytes)
    }

    override fun drain(): List<ByteArray> = emptyList()

    override fun close() = Unit
}

/**
 * Opus via the platform's MediaCodec, 16 kHz mono. Not JVM-testable (no
 * MediaCodec on the JVM test runner) - kept small and a direct translation
 * of the MediaCodec encoder contract, so it is reviewable by inspection:
 * feed PCM16 into input buffers, drain output buffers in order, and keep
 * the one BUFFER_FLAG_CODEC_CONFIG buffer as [config] rather than a packet.
 */
class MediaCodecOpusEncoder(
    sampleRate: Int = 16000,
    bitrate: Int = 32000,
    @Suppress("UNUSED_PARAMETER") frameMs: Int = 20,
) : AudioEncoder {
    override val codec = Codec.opus

    @Volatile private var mutableConfig: ByteArray? = null
    override val config: ByteArray? get() = mutableConfig

    private val mediaCodec: MediaCodec = MediaCodec.createEncoderByType(MIME).apply {
        val format = MediaFormat.createAudioFormat(MIME, sampleRate, 1).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        }
        configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        start()
    }

    override fun encode(samples: ShortArray, n: Int): List<ByteArray> {
        val bytes = ByteArray(n * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(samples, 0, n)
        feed(bytes, endOfStream = false)
        return drainAvailable(waitForEnd = false)
    }

    /** Signals end of stream and returns whatever packets the codec still had buffered. */
    override fun drain(): List<ByteArray> {
        feed(ByteArray(0), endOfStream = true)
        return drainAvailable(waitForEnd = true)
    }

    override fun close() {
        mediaCodec.stop()
        mediaCodec.release()
    }

    // Queues [bytes] into as many input buffers as the codec will accept right now.
    private fun feed(bytes: ByteArray, endOfStream: Boolean) {
        var offset = 0
        while (true) {
            val index = mediaCodec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) return
            val buffer = mediaCodec.getInputBuffer(index) ?: return
            val remaining = bytes.size - offset
            val toWrite = minOf(remaining, buffer.capacity())
            buffer.clear()
            if (toWrite > 0) buffer.put(bytes, offset, toWrite)
            val flags = if (endOfStream) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
            mediaCodec.queueInputBuffer(index, 0, toWrite, 0, flags)
            offset += toWrite
            if (offset >= bytes.size) return
        }
    }

    // Drains every output buffer the codec has ready. With [waitForEnd], keeps
    // polling (bounded) until the end-of-stream buffer comes back, since the
    // codec may need a few TRY_AGAIN_LATER rounds to flush internally.
    private fun drainAvailable(waitForEnd: Boolean): List<ByteArray> {
        val packets = mutableListOf<ByteArray>()
        val info = MediaCodec.BufferInfo()
        var idleRounds = 0
        while (true) {
            val index = mediaCodec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (index < 0) {
                if (waitForEnd && idleRounds++ < MAX_IDLE_ROUNDS) continue
                return packets
            }
            idleRounds = 0
            val buffer = mediaCodec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                val bytes = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(bytes)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    mutableConfig = bytes
                } else {
                    packets += bytes
                }
            }
            mediaCodec.releaseOutputBuffer(index, false)
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return packets
        }
    }

    private companion object {
        const val MIME = "audio/opus"
        const val TIMEOUT_US = 10_000L
        const val MAX_IDLE_ROUNDS = 50 // ~0.5 s of polling before giving up on end-of-stream
    }
}

/** Opus when the device has an encoder for it, PCM otherwise - never fails to produce an encoder. */
fun pickEncoder(): AudioEncoder {
    val hasOpus = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
        info.isEncoder && info.supportedTypes.any { it.equals("audio/opus", ignoreCase = true) }
    }
    if (!hasOpus) return PcmPassthrough()
    return try {
        MediaCodecOpusEncoder()
    } catch (e: Exception) {
        PcmPassthrough()
    }
}
