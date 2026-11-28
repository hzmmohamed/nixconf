package nixconf.phone.diary

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

// What DiaryRecording feeds PCM16 through before sealing it. [config] is
// the codec-specific data a reader needs before any packet makes sense
// (Opus: every CODEC_CONFIG buffer the codec has emitted so far,
// concatenated - see [opusHeadOf] for what that actually contains; PCM:
// none). Encoded packets are returned in call order; the caller frames/
// concatenates them per the on-disk format (see DiaryRecording).
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

private val OPUS_HEAD_MAGIC = "OpusHead".toByteArray(Charsets.US_ASCII)
private val AOPUSHDR_MAGIC = "AOPUSHDR".toByteArray(Charsets.US_ASCII)

/**
 * The raw OpusHead to store in [Entry.codecConfig], out of whatever a
 * MediaCodec audio/opus encoder emitted as its codec-config data ([AudioEncoder.config]):
 * either a config buffer that already *is* a raw OpusHead, or AOSP's
 * codec2 marker format - "AOPUSHDR" | u64 LE length | OpusHead, optionally
 * followed by "AOPUSDLY"/"AOPUSPRL" blocks (pre-skip/seek-preroll in ns)
 * this function has no use for and ignores. Null for anything else
 * (unrecognised, truncated, or a length that doesn't fit): the caller logs
 * a warning and stores no codecConfig rather than bytes a reader might
 * mistake for a real OpusHead. A pure function so it is JVM-testable even
 * though the encoder that produces its input is not (see OpusHeadTest).
 */
fun opusHeadOf(config: ByteArray): ByteArray? {
    if (startsWith(config, OPUS_HEAD_MAGIC)) {
        // A raw buffer has no declared length (unlike the marker format below): trim to the
        // OpusHead's own length, in case the encoder padded the buffer or appended anything else.
        val len = minOf(opusHeadLength(config), config.size)
        return config.copyOfRange(0, len)
    }
    if (!startsWith(config, AOPUSHDR_MAGIC)) return null
    val lenStart = AOPUSHDR_MAGIC.size
    val payloadStart = lenStart + 8
    if (config.size < payloadStart) return null
    val len = readU64LE(config, lenStart)
    if (len < 0 || len > config.size - payloadStart) return null
    return config.copyOfRange(payloadStart, payloadStart + len.toInt())
}

// The length of the OpusHead (RFC 7845 s.5.1) starting at offset 0 of [bytes]: the fixed
// 19-byte header up to and including the channel mapping family byte, plus - only when
// that family is non-zero - 2 bytes (stream count, coupled count) and one byte per channel.
private fun opusHeadLength(bytes: ByteArray): Int {
    if (bytes.size < 19) return bytes.size
    val family = bytes[18].toInt() and 0xFF
    if (family == 0) return 19
    if (bytes.size < 20) return bytes.size
    val channelCount = bytes[9].toInt() and 0xFF
    return 21 + channelCount
}

private fun startsWith(bytes: ByteArray, prefix: ByteArray): Boolean =
    bytes.size >= prefix.size && bytes.copyOfRange(0, prefix.size).contentEquals(prefix)

private fun readU64LE(bytes: ByteArray, offset: Int): Long {
    var v = 0L
    for (i in 0 until 8) v = v or ((bytes[offset + i].toLong() and 0xFF) shl (8 * i))
    // A length that doesn't fit a positive Int (a corrupt/hostile length prefix) is never
    // a real AOPUSHDR block: callers reject anything outside a sane range.
    return if (v < 0 || v > Int.MAX_VALUE) -1L else v
}

/**
 * Opus via the platform's MediaCodec, 16 kHz mono. Not JVM-testable (no
 * MediaCodec on the JVM test runner) - kept small and a direct translation
 * of the MediaCodec encoder contract, so it is reviewable by inspection:
 * feed PCM16 into input buffers, drain output buffers in order, and keep
 * every BUFFER_FLAG_CODEC_CONFIG buffer (concatenated) as [config] rather
 * than a packet - see [opusHeadOf] for what DiaryRecording extracts from it.
 */
class MediaCodecOpusEncoder(
    private val sampleRate: Int = 16000,
    bitrate: Int = 32000,
    @Suppress("UNUSED_PARAMETER") frameMs: Int = 20,
) : AudioEncoder {
    override val codec = Codec.opus

    @Volatile private var mutableConfig: ByteArray? = null
    override val config: ByteArray? get() = mutableConfig

    // Presentation timestamp of the next input buffer, in samples fed so far.
    private var samplesFed = 0L

    @Volatile private var closed = false

    private val mediaCodec: MediaCodec = run {
        val codec = MediaCodec.createEncoderByType(MIME)
        try {
            val format = MediaFormat.createAudioFormat(MIME, sampleRate, 1).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            codec
        } catch (e: Exception) {
            // Nothing usable was returned to the caller: release what MediaCodec did allocate.
            codec.release()
            throw e
        }
    }

    override fun encode(samples: ShortArray, n: Int): List<ByteArray> {
        val bytes = ByteArray(n * 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(samples, 0, n)
        // feed() may itself drain packets (to free an input buffer while stalled); those came
        // first, in time, so they go ahead of what drainAvailable collects afterwards here.
        val drainedWhileFeeding = feed(bytes, endOfStream = false)
        return drainedWhileFeeding + drainAvailable(waitForEnd = false)
    }

    /** Signals end of stream and returns whatever packets the codec still had buffered. */
    override fun drain(): List<ByteArray> {
        val drainedWhileFeeding = feed(ByteArray(0), endOfStream = true)
        return drainedWhileFeeding + drainAvailable(waitForEnd = true)
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            mediaCodec.stop()
        } finally {
            mediaCodec.release()
        }
    }

    // Queues [bytes] into as many input buffers as the codec will accept, draining
    // output in between to make room, until every byte (or, with [endOfStream], the
    // end-of-stream marker itself) has actually been queued. Bounded: no input buffer
    // becoming free for DEADLINE_NS straight gives up loudly (an encoder this stuck is
    // not going to recover) rather than silently dropping audio or spinning forever.
    // Returns whatever packets those in-between drains collected - they must not be
    // dropped (a stall then recovering is not a reason to lose audio).
    private fun feed(bytes: ByteArray, endOfStream: Boolean): List<ByteArray> {
        val drained = mutableListOf<ByteArray>()
        var offset = 0
        var deadline = System.nanoTime() + NO_PROGRESS_NS
        while (offset < bytes.size || (endOfStream && offset == 0 && bytes.isEmpty())) {
            val index = mediaCodec.dequeueInputBuffer(TIMEOUT_US)
            if (index < 0) {
                drained += drainAvailable(waitForEnd = false) // may free an input buffer
                check(System.nanoTime() < deadline) { "MediaCodec: no input buffer available" }
                continue
            }
            deadline = System.nanoTime() + NO_PROGRESS_NS
            val buffer = checkNotNull(mediaCodec.getInputBuffer(index)) { "MediaCodec: no input buffer at index $index" }
            val toWrite = minOf(bytes.size - offset, buffer.capacity())
            buffer.clear()
            if (toWrite > 0) buffer.put(bytes, offset, toWrite)
            val presentationUs = samplesFed * 1_000_000L / sampleRate
            val eos = endOfStream && offset + toWrite >= bytes.size
            mediaCodec.queueInputBuffer(index, 0, toWrite, presentationUs, if (eos) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
            samplesFed += toWrite / 2 // PCM16 mono: 2 bytes/sample
            offset += toWrite
            if (eos) return drained // end-of-stream queued
        }
        return drained
    }

    // Drains every output buffer the codec has ready. With [waitForEnd], keeps
    // polling (bounded) until the end-of-stream buffer comes back, since the
    // codec may need a few TRY_AGAIN_LATER rounds to flush internally.
    private fun drainAvailable(waitForEnd: Boolean): List<ByteArray> {
        val packets = mutableListOf<ByteArray>()
        val info = MediaCodec.BufferInfo()
        var deadline = System.nanoTime() + NO_PROGRESS_NS
        while (true) {
            val index = mediaCodec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (index < 0) {
                if (waitForEnd && System.nanoTime() < deadline) continue
                return packets
            }
            deadline = System.nanoTime() + NO_PROGRESS_NS
            val buffer = mediaCodec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                val bytes = ByteArray(info.size)
                buffer.position(info.offset)
                buffer.get(bytes)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    mutableConfig = (mutableConfig ?: ByteArray(0)) + bytes
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
        const val NO_PROGRESS_NS = 1_000_000_000L // ~1 s of no progress before giving up
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
