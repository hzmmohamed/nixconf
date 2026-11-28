package nixconf.phone.diary

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.KeyPair
import java.security.KeyPairGenerator
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test

class EntryCipherTest {
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

    private fun recipients() = listOf(
        Recipient("device:diary-device-v1", device.public),
        Recipient("recovery:abcd", recovery.public),
    )

    private fun frames(n: Int) = (0 until n).map { "frame-$it-payload".toByteArray() }

    private fun sealed(key: EntryKey, role: Byte, plains: List<ByteArray>): ByteArrayOutputStream {
        val out = ByteArrayOutputStream()
        out.write(key.header())
        val writer = FrameWriter(out, key, role)
        for (p in plains) writer.write(p)
        return out
    }

    @Test
    fun roundtrip_two_recipients() {
        val key = EntryKey.new(recipients())
        val plains = frames(3)
        val sealed = sealed(key, ROLE_META, plains)
        val bytes = sealed.toByteArray()

        val headerIn1 = ByteArrayInputStream(bytes)
        val header1 = readHeader(headerIn1)
        val deviceKey = EntryKey.open(header1, device.private, "device:")
        val fromDevice = FrameReader(headerIn1, deviceKey, ROLE_META).asSequence().toList()
        assertEquals(plains.map { String(it) }, fromDevice.map { String(it) })

        val headerIn2 = ByteArrayInputStream(bytes)
        val header2 = readHeader(headerIn2)
        val recoveryKey = EntryKey.open(header2, recovery.private, "recovery:")
        val fromRecovery = FrameReader(headerIn2, recoveryKey, ROLE_META).asSequence().toList()
        assertEquals(plains.map { String(it) }, fromRecovery.map { String(it) })
    }

    @Test(expected = KeyUnavailable::class)
    fun wrong_private_key_throws_key_unavailable() {
        val key = EntryKey.new(recipients())
        val bytes = sealed(key, ROLE_META, frames(1)).toByteArray()
        val header = readHeader(ByteArrayInputStream(bytes))

        val other = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.genKeyPair()
        EntryKey.open(header, other.private, "device:")
    }

    @Test
    fun truncated_tail_keeps_earlier_frames() {
        val key = EntryKey.new(recipients())
        val plains = frames(3)
        val bytes = sealed(key, ROLE_AUDIO, plains).toByteArray()
        val truncated = bytes.copyOfRange(0, bytes.size - 5)

        val input = ByteArrayInputStream(truncated)
        val header = readHeader(input)
        val readKey = EntryKey.open(header, device.private, "device:")
        val out = FrameReader(input, readKey, ROLE_AUDIO).asSequence().toList()

        assertEquals(2, out.size)
        assertEquals(String(plains[0]), String(out[0]))
        assertEquals(String(plains[1]), String(out[1]))
    }

    @Test
    fun tampered_frame_stops_there() {
        val key = EntryKey.new(recipients())
        val plains = frames(3)
        val bytes = sealed(key, ROLE_AUDIO, plains).toByteArray()

        // Flip a byte inside the second frame's ciphertext.
        val headerLen = key.header().size
        val secondFrameStart = headerLen + (4 + plains[0].size + 16)
        val tampered = bytes.copyOf()
        tampered[secondFrameStart + 4] = (tampered[secondFrameStart + 4].toInt() xor 0xFF).toByte()

        val input = ByteArrayInputStream(tampered)
        val header = readHeader(input)
        val readKey = EntryKey.open(header, device.private, "device:")
        val out = FrameReader(input, readKey, ROLE_AUDIO).asSequence().toList()

        assertEquals(1, out.size)
        assertEquals(String(plains[0]), String(out[0]))
    }

    @Test
    fun frames_not_reorderable() {
        val key = EntryKey.new(recipients())
        val plains = frames(3)
        val bytes = sealed(key, ROLE_AUDIO, plains).toByteArray()
        val headerLen = key.header().size

        // Frame layout: each is u32 len | ct (ct = plaintext + 16-byte GCM tag).
        val frameLen = 4 + plains[0].size + 16
        val frame1 = bytes.copyOfRange(headerLen, headerLen + frameLen)
        val frame2 = bytes.copyOfRange(headerLen + frameLen, headerLen + 2 * frameLen)
        val swapped = bytes.copyOf()
        System.arraycopy(frame2, 0, swapped, headerLen, frameLen)
        System.arraycopy(frame1, 0, swapped, headerLen + frameLen, frameLen)

        val input = ByteArrayInputStream(swapped)
        val header = readHeader(input)
        val readKey = EntryKey.open(header, device.private, "device:")
        val out = FrameReader(input, readKey, ROLE_AUDIO).asSequence().toList()

        // Frame 0 is untouched and still reads; the swapped index-1 slot now
        // holds what was encrypted under AAD index 2, so it fails there.
        assertEquals(1, out.size)
        assertEquals(String(plains[0]), String(out[0]))
    }

    @Test
    fun meta_frame_not_readable_as_audio() {
        val key = EntryKey.new(recipients())
        val bytes = sealed(key, ROLE_META, frames(1)).toByteArray()

        val input = ByteArrayInputStream(bytes)
        val header = readHeader(input)
        val readKey = EntryKey.open(header, device.private, "device:")
        val out = FrameReader(input, readKey, ROLE_AUDIO).asSequence().toList()

        assertTrue(out.isEmpty())
    }

    @Test
    fun header_roundtrips_recipient_ids_and_nonce_prefix() {
        val key = EntryKey.new(recipients())
        val bytes = key.header()
        val header = readHeader(ByteArrayInputStream(bytes))
        assertEquals(setOf("device:diary-device-v1", "recovery:abcd"), header.recipients.keys)
        assertEquals(4, header.noncePrefix.size)
    }

    @Test
    fun bad_magic_is_rejected() {
        val bad = "XXXX".toByteArray() + byteArrayOf(0)
        try {
            readHeader(ByteArrayInputStream(bad))
            assertFalse("expected IOException", true)
        } catch (e: java.io.IOException) {
            // expected
        }
    }
}
