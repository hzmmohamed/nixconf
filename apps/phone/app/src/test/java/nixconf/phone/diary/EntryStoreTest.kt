package nixconf.phone.diary

import java.io.File
import java.io.FileOutputStream
import java.security.KeyPair
import java.security.KeyPairGenerator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

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

        // A stale .tmp left behind by a previous (interrupted) rewrite must not be mistaken for meta.
        File(File(tmp.root, id), "meta.pdy.tmp").writeBytes(byteArrayOf(1, 2, 3))

        val listed = store.list(device.private)
        assertEquals(1, listed.size)
        assertEquals(State.Done, listed[0].entry!!.state)
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

        val frames = storeB.openForRead(id, device.private).audioFrames().asSequence().toList()
        assertEquals(2, frames.size)
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
