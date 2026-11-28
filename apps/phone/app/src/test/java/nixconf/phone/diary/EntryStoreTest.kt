package nixconf.phone.diary

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.KeyPair
import java.security.KeyPairGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** A FileOutputStream that throws on its [failOnCall]-th raw write() call; used to inject a mid-frame disk failure. */
private class FailingAfterWrites(file: File, private val failOnCall: Int) : FileOutputStream(file) {
    private var calls = 0

    override fun write(b: ByteArray, off: Int, len: Int) {
        calls++
        if (calls == failOnCall) throw IOException("injected failure (test)")
        super.write(b, off, len)
    }

    override fun write(b: ByteArray) = write(b, 0, b.size)
}

class EntryStoreTest {
    companion object {
        // 2048 bits keeps the suite fast; production uses 3072 (enforced in Task 6).
        private lateinit var device: KeyPair
        private lateinit var recovery: KeyPair

        @BeforeClass
        @JvmStatic
        fun generateKeys() {
            val gen = KeyPairGenerator.getInstance("RSA")
            gen.initialize(2048)
            device = gen.genKeyPair()
            recovery = gen.genKeyPair()
        }
    }

    @get:Rule val tmp = TemporaryFolder()

    private var now = 1_795_000_000_000L
    private fun recipients() = listOf(
        Recipient("device:diary-device-v1", device.public),
        Recipient("recovery:abcd", recovery.public),
    )
    private fun newStore() = EntryStore(tmp.root, ::recipients, { now })

    @Test
    fun create_and_write_need_no_private_key() {
        // Public recipients only - no private key anywhere in this block.
        val store = EntryStore(tmp.root, { listOf(Recipient("device:diary-device-v1", device.public)) }, { now })
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        open.appendAudio("chunk-0".toByteArray())
        open.appendAudio("chunk-1".toByteArray())
        open.appendAudio("chunk-2".toByteArray())
        open.update { it.copy(mood = Mood(scale = 3)) }
        open.finish(1500)

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        val entry = listed[0].entry!!
        assertEquals(3, entry.mood?.scale)
        assertEquals(State.Done, entry.state)
        assertEquals(1500L, entry.durationMs)
    }

    @Test
    fun no_plaintext_on_disk() {
        val store = newStore()
        val open = store.create(Kind.typed, Codec.pcm_s16le, "Africa/Cairo")
        open.appendAudio("PLAINAUDIO".toByteArray(Charsets.US_ASCII))
        open.update { it.copy(text = "SECRET-هادي") }
        open.finish(0)

        val secretUtf8 = "SECRET-هادي".toByteArray(Charsets.UTF_8)
        val secretUtf16 = "SECRET-هادي".toByteArray(Charsets.UTF_16)
        val audioAscii = "PLAINAUDIO".toByteArray(Charsets.US_ASCII)
        tmp.root.walkTopDown().filter { it.isFile }.forEach { f ->
            val bytes = f.readBytes()
            assertFalse("found secret text in $f", contains(bytes, secretUtf8))
            assertFalse("found secret text (utf16) in $f", contains(bytes, secretUtf16))
            assertFalse("found plain audio in $f", contains(bytes, audioAscii))
        }
    }

    private fun contains(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || needle.size > haystack.size) return false
        outer@ for (i in 0..haystack.size - needle.size) {
            for (j in needle.indices) {
                if (haystack[i + j] != needle[j]) continue@outer
            }
            return true
        }
        return false
    }

    @Test
    fun meta_rewrite_is_atomic() {
        val store = newStore()
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        open.update { it.copy(mood = Mood(scale = 2)) }
        val id = open.entry.id
        open.finish(0)

        // A stale .tmp left behind by a previous (interrupted) rewrite, next to a *good* meta.pdy,
        // must not be mistaken for meta: meta.pdy always wins when it's there.
        File(File(tmp.root, id), "meta.pdy.tmp").writeBytes(byteArrayOf(1, 2, 3))

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertEquals(State.Done, listed[0].entry!!.state)
    }

    @Test
    fun missing_meta_falls_back_to_tmp() {
        val store = newStore()
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        open.update { it.copy(mood = Mood(scale = 4)) }
        val id = open.entry.id
        open.finish(0)

        // Simulate a crash between writing meta.pdy.tmp and renaming it away: the tmp still
        // holds a good, decodable frame, and the real meta.pdy never made it (or was removed).
        val dir = File(tmp.root, id)
        File(dir, "meta.pdy").copyTo(File(dir, "meta.pdy.tmp"), overwrite = true)
        assertTrue(File(dir, "meta.pdy").delete())

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertNull(listed[0].error)
        assertEquals(State.Done, listed[0].entry!!.state)
        assertEquals(4, listed[0].entry!!.mood?.scale)
    }

    @Test
    fun interrupted_entry_is_listed() {
        val storeA = newStore()
        val open = storeA.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        val id = open.entry.id
        open.appendAudio("chunk-0".toByteArray())
        open.appendAudio("chunk-1".toByteArray())
        // open is dropped here (simulating a kill) without finish(): storeA's activeId still
        // holds it, so a *new* EntryStore instance is needed to see it as unattended.

        val storeB = newStore()
        val listed = storeB.list(device.private)
        assertEquals(1, listed.size)
        assertEquals(id, listed[0].id)
        assertEquals(State.Interrupted, listed[0].entry!!.state)

        val frames = storeB.openForRead(id, device.private).useAudioFrames { seq -> seq.map { String(it) }.toList() }
        assertEquals(listOf("chunk-0", "chunk-1"), frames)
    }

    @Test
    fun open_for_read_reports_interrupted() {
        val storeA = newStore()
        val open = storeA.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        val id = open.entry.id
        // Dropped without finish(): storeA still thinks it's active, but a fresh instance
        // (storeB, activeId == null) has no live writer for it.

        val storeB = newStore()
        val read = storeB.openForRead(id, device.private)
        assertEquals(State.Interrupted, read.entry.state)
    }

    @Test
    fun failed_append_truncates_and_closes() {
        val store = newStore()
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        val id = open.entry.id

        // Fail on the 4th raw write(): header (1), frame-0 length+ciphertext (2, 3), then the
        // length prefix of frame 1 (4) - so frame 0 is fully on disk and frame 1 never starts.
        store.openAudioStream = { f -> FailingAfterWrites(f, failOnCall = 4) }

        open.appendAudio("chunk-0".toByteArray())
        try {
            open.appendAudio("chunk-1".toByteArray())
            fail("expected the injected write failure to propagate")
        } catch (e: IOException) {
            // expected
        }

        // The entry is closed for writing: no retry, no reused frame index/nonce.
        try {
            open.appendAudio("chunk-2".toByteArray())
            fail("expected appendAudio to fail fast after a write failure")
        } catch (e: IOException) {
            assertEquals("entry closed after a write failure", e.message)
        }

        // Exactly one (unreadable-as-garbage) frame made it to disk.
        val frames = store.openForRead(id, device.private).useAudioFrames { seq -> seq.map { String(it) }.toList() }
        assertEquals(listOf("chunk-0"), frames)
    }

    @Test
    fun hidden_entries_flagged() {
        val store = newStore()
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        val id = open.entry.id
        open.finish(0)

        store.setHidden(id, true, device.private)

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertTrue(listed[0].entry!!.hidden)
        assertTrue(File(tmp.root, id).isDirectory)
    }

    @Test
    fun unreadable_meta_listed_with_error() {
        val store = newStore()
        val open = store.create(Kind.spoken, Codec.opus, "Africa/Cairo")
        val id = open.entry.id
        open.finish(0)

        FileOutputStream(File(File(tmp.root, id), "meta.pdy")).use { it.write("not a sealed entry".toByteArray()) }

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertNull(listed[0].entry)
        assertNotNull(listed[0].error)
    }
}
