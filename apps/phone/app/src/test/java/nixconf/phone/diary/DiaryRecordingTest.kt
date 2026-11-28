package nixconf.phone.diary

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyPair
import java.security.KeyPairGenerator
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.flow.MutableStateFlow
import nixconf.phone.audio.PcmSink
import nixconf.phone.session.AudioSource
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** A FileOutputStream that throws on its [failOnCall]-th raw write() call; see EntryStoreTest for the raw-write accounting. */
private class DiaryFailingAfterWrites(file: File, private val failOnCall: Int) : FileOutputStream(file) {
    private var calls = 0

    override fun write(b: ByteArray, off: Int, len: Int) {
        calls++
        if (calls == failOnCall) throw IOException("injected failure (test)")
        super.write(b, off, len)
    }

    override fun write(b: ByteArray) = write(b, 0, b.size)
}

/**
 * Drives a [PcmSink] the way Recorder's loop does, but synchronously and on
 * the test's own schedule: [push] feeds [samples] in [chunk]-sized reads,
 * calling [PcmSink.flush] every [flushEvery] samples (stopping early if
 * [stop] was called meanwhile, as a real recording thread would see
 * `running` go false).
 */
private class FakeAudioSource : AudioSource {
    override val level = MutableStateFlow(0f)
    private var sink: PcmSink? = null
    var running = false

    override fun start(out: PcmSink, tap: ((ShortArray, Int) -> Unit)?) {
        sink = out
        running = true
    }

    override fun stop() {
        running = false
    }

    fun push(samples: ShortArray, chunk: Int, flushEvery: Int) {
        val out = sink ?: return
        var pos = 0
        var sinceFlush = 0
        while (pos < samples.size && running) {
            val n = minOf(chunk, samples.size - pos)
            out.write(samples.copyOfRange(pos, pos + n), n)
            pos += n
            sinceFlush += n
            if (sinceFlush >= flushEvery) {
                out.flush()
                sinceFlush = 0
            }
        }
    }
}

class DiaryRecordingTest {
    companion object {
        private lateinit var device: KeyPair

        @BeforeClass
        @JvmStatic
        fun generateKeys() {
            val gen = KeyPairGenerator.getInstance("RSA")
            gen.initialize(2048) // production uses 3072; 2048 keeps the suite fast
            device = gen.genKeyPair()
        }
    }

    @get:Rule val tmp = TemporaryFolder()

    private val now = 1_795_000_000_000L
    private val sampleRate = 16000

    // 3 s of a 440 Hz tone: deterministic, non-silent, easy to compare byte for byte.
    private val samples = ShortArray(3 * sampleRate) { i -> (sin(2 * PI * 440 * i / sampleRate) * 10000).toInt().toShort() }

    private fun newStore() = EntryStore(tmp.root, { listOf(Recipient("device:diary-device-v1", device.public)) }, { now })

    private fun toBytes(s: ShortArray): ByteArray {
        val buf = ByteBuffer.allocate(s.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        buf.asShortBuffer().put(s)
        return buf.array()
    }

    private fun framesOf(store: EntryStore, id: String): List<ByteArray> =
        store.openForRead(id, device.private).useAudioFrames { seq -> seq.toList() }

    @Test
    fun records_flushes_and_saves() {
        val store = newStore()
        val audio = FakeAudioSource()
        val rec = DiaryRecording(store, audio, { PcmPassthrough() }, { "Africa/Cairo" }, now = { now })

        rec.start()
        audio.push(samples, chunk = 1600, flushEvery = 2 * sampleRate)
        rec.stop()

        val state = rec.state.value
        assertTrue(state is RecState.Saved)
        val saved = state as RecState.Saved
        assertEquals(3000L, saved.durationMs)

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertEquals(saved.entryId, listed[0].id)
        assertEquals(State.Done, listed[0].entry!!.state)
        assertEquals(3000L, listed[0].entry!!.durationMs)

        val concatenated = ByteArrayOutputStream().apply { framesOf(store, saved.entryId).forEach { write(it) } }.toByteArray()
        assertArrayEquals(toBytes(samples), concatenated)
    }

    @Test
    fun flush_writes_one_frame_per_interval() {
        val store = newStore()
        val audio = FakeAudioSource()
        val rec = DiaryRecording(store, audio, { PcmPassthrough() }, { "Africa/Cairo" }, flushMs = 2000, now = { now })

        rec.start()
        audio.push(samples, chunk = 1600, flushEvery = 2 * sampleRate) // flush at 2 s, DiaryRecording seals the last 1 s at stop
        rec.stop()

        val id = (rec.state.value as RecState.Saved).entryId
        assertEquals(2, framesOf(store, id).size)
    }

    @Test
    fun sink_failure_stops_and_reports() {
        val store = newStore()
        // 1st appendAudio (header + frame-0 len/ct: calls 1-3) succeeds; the 2nd's
        // first raw write (frame-1's length prefix, call 4) fails.
        store.openAudioStream = { f -> DiaryFailingAfterWrites(f, failOnCall = 4) }
        val audio = FakeAudioSource()
        val rec = DiaryRecording(store, audio, { PcmPassthrough() }, { "Africa/Cairo" }, flushMs = 2000, now = { now })

        rec.start()
        audio.push(samples, chunk = 1600, flushEvery = 2 * sampleRate)
        rec.stop() // the 2nd appendAudio call (sealing the last 1 s) is where the injected failure hits

        val state = rec.state.value
        assertTrue(state is RecState.Failed)
        val failed = state as RecState.Failed
        assertEquals("Storage is full: the recording was saved up to here", failed.message)
        assertFalse(audio.running)

        val frames = framesOf(store, failed.entryId!!)
        assertEquals(1, frames.size)
        assertArrayEquals(toBytes(samples.copyOfRange(0, 2 * sampleRate)), frames[0])
    }

    @Test
    fun start_twice_is_ignored() {
        val store = newStore()
        val audio = FakeAudioSource()
        val rec = DiaryRecording(store, audio, { PcmPassthrough() }, { "Africa/Cairo" }, now = { now })

        rec.start()
        val id = (rec.state.value as RecState.Recording).entryId
        rec.start() // ignored: already recording
        assertEquals(id, (rec.state.value as RecState.Recording).entryId)

        rec.stop()
        assertEquals(1, store.list(device.private).size)
    }
}
