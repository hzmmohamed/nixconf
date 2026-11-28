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
    fun raw_opushead_with_trailing_bytes_trims_to_the_header() {
        // A raw buffer has no declared length, unlike the marker format: opusHeadOf must work
        // out the real OpusHead length itself and trim, not return whatever padding/extra
        // bytes the encoder's buffer happened to carry alongside it.
        val config = head + byteArrayOf(9, 9, 9, 9)
        assertArrayEquals(head, opusHeadOf(config))
    }

    @Test
    fun raw_opushead_with_channel_mapping_includes_the_mapping_table() {
        // Channel mapping family != 0: the header extends past the fixed 19 bytes with a
        // stream count, a coupled count, and one mapping byte per channel (2, here).
        val fixedPart = "OpusHead".toByteArray(Charsets.US_ASCII) + byteArrayOf(1, 2, 0, 1, 56, 1, 0, 0, 0, 0, 1)
        val mappingTable = byteArrayOf(1, 0, 0, 1) // stream count, coupled count, 2-channel mapping
        val expected = fixedPart + mappingTable
        val config = expected + byteArrayOf(9, 9) // trailing bytes, as above
        assertArrayEquals(expected, opusHeadOf(config))
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
