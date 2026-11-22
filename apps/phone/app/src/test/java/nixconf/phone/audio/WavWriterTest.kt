package nixconf.phone.audio

import java.io.File
import java.io.RandomAccessFile
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WavWriterTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun header(file: File, offset: Long): Int = RandomAccessFile(file, "r").use {
        it.seek(offset)
        Integer.reverseBytes(it.readInt())
    }

    private fun ramp(n: Int) = ShortArray(n) { (it % 2000 - 1000).toShort() }

    @Test
    fun header_sizes_patched_on_close() {
        val file = tmp.newFile("a.wav")
        val samples = ramp(16000)
        WavWriter(file).apply {
            write(samples, 8000)
            write(samples.copyOfRange(8000, 16000), 8000)
            close()
        }
        assertEquals(32044L, file.length())
        assertEquals(32036, header(file, 4))
        assertEquals(32000, header(file, 40))
        assertEquals(16000, header(file, 24))
        assertArrayEquals(samples, WavFiles.readSamples(file))
        assertFalse(WavFiles.repair(file))
    }

    @Test
    fun writes_only_the_first_n_samples() {
        val file = tmp.newFile("a.wav")
        WavWriter(file).apply {
            write(ramp(100), 10)
            close()
        }
        assertEquals(10, WavFiles.readSamples(file).size)
    }

    @Test
    fun unpatched_file_is_repaired() {
        val file = tmp.newFile("a.wav")
        val samples = ramp(16000)
        // App killed mid-recording: flushed, never closed.
        WavWriter(file).apply {
            write(samples, samples.size)
            flush()
        }
        assertEquals(0, header(file, 40))

        assertTrue(WavFiles.repair(file))
        assertEquals(32036, header(file, 4))
        assertEquals(32000, header(file, 40))
        assertEquals(16000, WavFiles.readSamples(file).size)
        assertArrayEquals(samples, WavFiles.readSamples(file))
    }

    @Test
    fun torn_last_sample_is_dropped_on_repair() {
        val file = tmp.newFile("a.wav")
        WavWriter(file).apply {
            write(ramp(10), 10)
            flush()
        }
        RandomAccessFile(file, "rw").use { it.seek(it.length()); it.write(7) }
        assertTrue(WavFiles.repair(file))
        assertEquals(20, header(file, 40))
        assertEquals(10, WavFiles.readSamples(file).size)
    }
}
