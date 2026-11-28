package nixconf.phone.audio

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

// 16-bit mono PCM WAV, written as it is recorded. The header's sizes stay 0
// until close(); a file left behind by a killed app is fixed by
// WavFiles.repair, so flush() (fsync) is all that is needed to keep audio.
class WavWriter(file: File, private val sampleRate: Int = 16000) : PcmSink {
    private val out = RandomAccessFile(file, "rw")
    private var dataBytes = 0L

    init {
        out.setLength(0)
        out.write(WavFiles.header(sampleRate))
    }

    override fun write(samples: ShortArray, n: Int) {
        val buf = ByteBuffer.allocate(n * 2).order(ByteOrder.LITTLE_ENDIAN)
        buf.asShortBuffer().put(samples, 0, n)
        out.write(buf.array())
        dataBytes += n * 2
    }

    override fun flush() = out.fd.sync()

    fun close() {
        out.use {
            WavFiles.patchSizes(it, dataBytes)
            it.fd.sync()
        }
    }
}

object WavFiles {
    const val HEADER_SIZE = 44

    // Sizes 0: unknown until close() (or repair()).
    internal fun header(sampleRate: Int): ByteArray =
        ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray())
            putInt(0)
            put("WAVE".toByteArray())
            put("fmt ".toByteArray())
            putInt(16)
            putShort(1) // PCM
            putShort(1) // mono
            putInt(sampleRate)
            putInt(sampleRate * 2) // byte rate
            putShort(2) // block align
            putShort(16) // bits per sample
            put("data".toByteArray())
            putInt(0)
        }.array()

    internal fun patchSizes(file: RandomAccessFile, dataBytes: Long) {
        file.seek(4)
        file.writeInt(Integer.reverseBytes((36 + dataBytes).toInt()))
        file.seek(40)
        file.writeInt(Integer.reverseBytes(dataBytes.toInt()))
    }

    private fun dataSize(file: RandomAccessFile): Int {
        file.seek(40)
        return Integer.reverseBytes(file.readInt())
    }

    /** Fills in the sizes of a file whose header still says 0 (never closed). True if it changed. */
    fun repair(file: File): Boolean {
        if (file.length() <= HEADER_SIZE) return false
        return RandomAccessFile(file, "rw").use {
            if (dataSize(it) != 0) return false
            // A sample torn by the kill is dropped.
            val dataBytes = (it.length() - HEADER_SIZE) and 1L.inv()
            it.setLength(HEADER_SIZE + dataBytes)
            patchSizes(it, dataBytes)
            it.fd.sync()
            true
        }
    }

    /** Writes a whole file at once: a segment, from the segmenter's samples in -1..1. */
    fun write(file: File, samples: FloatArray, sampleRate: Int = 16000) {
        val pcm = ShortArray(samples.size) { (samples[it] * 32768f).roundToInt().coerceIn(-32768, 32767).toShort() }
        WavWriter(file, sampleRate).apply { write(pcm, pcm.size) }.close()
    }

    /** Samples of a file written by [WavWriter] (fixed 44-byte header), repaired or not. */
    fun readSamples(file: File): ShortArray = RandomAccessFile(file, "r").use {
        if (it.length() < HEADER_SIZE) throw IOException("$file: not a WAV file")
        val available = it.length() - HEADER_SIZE
        val size = dataSize(it).toLong().takeIf { s -> s in 1..available } ?: available
        val bytes = ByteArray((size and 1L.inv()).toInt())
        it.seek(HEADER_SIZE.toLong())
        it.readFully(bytes)
        val samples = ShortArray(bytes.size / 2)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
        samples
    }
}
