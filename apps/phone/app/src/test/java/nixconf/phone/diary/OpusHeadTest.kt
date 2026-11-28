package nixconf.phone.diary

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

private fun u64le(v: Long): ByteArray {
    val b = ByteArray(8)
    var x = v
    for (i in 0 until 8) {
        b[i] = (x and 0xFF).toByte()
        x = x ushr 8
    }
    return b
}

/** [opusHeadOf] parses what a MediaCodec audio/opus encoder's codec-config buffer can look like; see OpusEncoder.kt. */
class OpusHeadTest {
    private val head = "OpusHead".toByteArray(Charsets.US_ASCII) + byteArrayOf(1, 2, 0, 1, 56, 1, 0, 0, 0, 0, 0)

    @Test
    fun raw_opushead_returns_itself() {
        assertArrayEquals(head, opusHeadOf(head))
    }

    @Test
    fun marker_format_extracts_opushead_payload() {
        // AOSP codec2's wrapped format: AOPUSHDR|len|OpusHead, then (ignored) AOPUSDLY/AOPUSPRL blocks.
        val hdrBlock = "AOPUSHDR".toByteArray(Charsets.US_ASCII) + u64le(head.size.toLong()) + head
        val dlyBlock = "AOPUSDLY".toByteArray(Charsets.US_ASCII) + u64le(8L) + u64le(0L)
        val prlBlock = "AOPUSPRL".toByteArray(Charsets.US_ASCII) + u64le(8L) + u64le(0L)
        val config = hdrBlock + dlyBlock + prlBlock
        assertArrayEquals(head, opusHeadOf(config))
    }

    @Test
    fun marker_format_with_only_the_header_block() {
        val config = "AOPUSHDR".toByteArray(Charsets.US_ASCII) + u64le(head.size.toLong()) + head
        assertArrayEquals(head, opusHeadOf(config))
    }

    @Test
    fun garbage_returns_null() {
        assertNull(opusHeadOf(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)))
    }

    @Test
    fun empty_returns_null() {
        assertNull(opusHeadOf(ByteArray(0)))
    }

    @Test
    fun truncated_marker_length_returns_null() {
        // Claims a payload far larger than what actually follows: must not throw or over-read.
        val config = "AOPUSHDR".toByteArray(Charsets.US_ASCII) + u64le(1_000_000L) + head
        assertNull(opusHeadOf(config))
    }
}
