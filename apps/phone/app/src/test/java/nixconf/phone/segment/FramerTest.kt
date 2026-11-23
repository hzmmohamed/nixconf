package nixconf.phone.segment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FramerTest {
    @Test
    fun reads_of_any_length_become_512_sample_frames() {
        val framer = Framer()
        val frames = mutableListOf<FloatArray>()
        val read = ShortArray(1600) { (it % 100).toShort() }
        framer.push(read, 1600) { frames += it }
        assertEquals(3, frames.size) // 1536; 64 samples wait for the next read
        framer.push(ShortArray(500) { -16384 }, 500) { frames += it }
        assertEquals(4, frames.size)
        assertEquals(0f, frames[0][0])
        assertEquals(12 / 32768f, frames[0][12])
        assertEquals((1599 % 100) / 32768f, frames[3][63])
        assertEquals(-0.5f, frames[3][64])
        frames.forEach { assertEquals(FRAME, it.size) }
        // Each frame is its own array (the segmenter keeps them).
        for (i in frames.indices) for (j in 0 until i) assertTrue(frames[i] !== frames[j])
    }
}
