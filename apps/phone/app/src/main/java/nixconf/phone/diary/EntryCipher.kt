package nixconf.phone.diary

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec

// Sealed entry file format, version 1. Read by this module and by the
// offline Python recovery tool (Task 4), so the byte layout here is load-bearing:
//
// header: magic "PDY1" | u8 recipient_count | per recipient: u8 id_len, id (ascii),
//         u16 wrapped_len, wrapped (RSA-OAEP-SHA256 of the 32-byte entry key)
//         | 4-byte nonce_prefix
// frames: repeated  u32 ct_len | ct  (AES-256-GCM, nonce = nonce_prefix . u64 frame_index,
//         AAD = "PDY1" . file_role byte (0x01 meta, 0x02 audio) . u64 frame_index)
//
// A meta file has exactly one frame; an audio file has one frame per flushed
// chunk. Readers stop at the first frame that is short or fails authentication
// and keep everything decoded before it (see FrameReader).

const val ROLE_META: Byte = 1
const val ROLE_AUDIO: Byte = 2

private val MAGIC = byteArrayOf('P'.code.toByte(), 'D'.code.toByte(), 'Y'.code.toByte(), '1'.code.toByte())
private const val NONCE_PREFIX_LEN = 4
private const val KEY_BYTES = 32
private const val GCM_TAG_BITS = 128
private val OAEP_SPEC = OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, PSource.PSpecified.DEFAULT)

/** A public key an entry key is wrapped to; [id] e.g. "device:diary-device-v1" or "recovery:<fingerprint>". */
class Recipient(val id: String, val publicKey: PublicKey)

/** The header as parsed off the wire: each recipient's still-wrapped key, and the file's nonce prefix. */
class Header(val recipients: Map<String, ByteArray>, val noncePrefix: ByteArray)

/** No private key in hand unwraps the entry key (wrong key, or the Keystore key was invalidated). */
class KeyUnavailable(cause: Throwable) : Exception(cause)

/**
 * The per-entry AES-256-GCM key: unique per entry, wrapped with RSA-OAEP to
 * every recipient so either the device key or the recovery key opens it.
 * [header] is written once, up front; frames follow it.
 */
class EntryKey private constructor(
    private val secret: ByteArray,
    private val noncePrefix: ByteArray,
    private val wrapped: Map<String, ByteArray>,
) {
    private val keySpec = SecretKeySpec(secret, "AES")

    /** The exact header bytes for this entry: magic, recipients, nonce prefix. */
    fun header(): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(MAGIC)
        out.write(wrapped.size)
        for ((id, w) in wrapped) {
            val idBytes = id.toByteArray(Charsets.US_ASCII)
            out.write(idBytes.size)
            out.write(idBytes)
            out.write((w.size ushr 8) and 0xFF)
            out.write(w.size and 0xFF)
            out.write(w)
        }
        out.write(noncePrefix)
        return out.toByteArray()
    }

    private fun nonceFor(frameIndex: Long): ByteArray =
        ByteBuffer.allocate(noncePrefix.size + 8).put(noncePrefix).putLong(frameIndex).array()

    private fun aad(role: Byte, frameIndex: Long): ByteArray =
        ByteBuffer.allocate(MAGIC.size + 1 + 8).put(MAGIC).put(role).putLong(frameIndex).array()

    internal fun encrypt(plain: ByteArray, role: Byte, frameIndex: Long): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(GCM_TAG_BITS, nonceFor(frameIndex)))
        cipher.updateAAD(aad(role, frameIndex))
        return cipher.doFinal(plain)
    }

    /** Throws (AEADBadTagException or similar) on a bad tag; the caller treats that as end-of-stream. */
    internal fun decrypt(ct: ByteArray, role: Byte, frameIndex: Long): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(GCM_TAG_BITS, nonceFor(frameIndex)))
        cipher.updateAAD(aad(role, frameIndex))
        return cipher.doFinal(ct)
    }

    companion object {
        /** A fresh random entry key, wrapped to every recipient. */
        fun new(recipients: List<Recipient>, random: SecureRandom = SecureRandom()): EntryKey {
            val secret = ByteArray(KEY_BYTES).also { random.nextBytes(it) }
            val noncePrefix = ByteArray(NONCE_PREFIX_LEN).also { random.nextBytes(it) }
            val wrapped = LinkedHashMap<String, ByteArray>()
            for (r in recipients) {
                val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                cipher.init(Cipher.ENCRYPT_MODE, r.publicKey, OAEP_SPEC)
                wrapped[r.id] = cipher.doFinal(secret)
            }
            return EntryKey(secret, noncePrefix, wrapped)
        }

        /**
         * Unwraps the entry key from [header] using [privateKey], trying every
         * recipient whose id starts with [idPrefix] ("device:" or "recovery:").
         * Throws [KeyUnavailable] when none of them unwrap.
         */
        fun open(header: Header, privateKey: PrivateKey, idPrefix: String): EntryKey {
            var lastError: Throwable? = null
            for ((id, w) in header.recipients) {
                if (!id.startsWith(idPrefix)) continue
                try {
                    val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                    cipher.init(Cipher.DECRYPT_MODE, privateKey, OAEP_SPEC)
                    val secret = cipher.doFinal(w)
                    return EntryKey(secret, header.noncePrefix, header.recipients)
                } catch (e: Exception) {
                    lastError = e
                }
            }
            throw KeyUnavailable(lastError ?: IOException("no recipient matches '$idPrefix'"))
        }
    }
}

/** Parses the header written by [EntryKey.header] off [input], positioned at its start. */
fun readHeader(input: InputStream): Header {
    val magic = ByteArray(MAGIC.size)
    readFully(input, magic)
    if (!magic.contentEquals(MAGIC)) throw IOException("bad magic: not a sealed entry file")
    val count = readU8(input)
    val recipients = LinkedHashMap<String, ByteArray>()
    repeat(count) {
        val idLen = readU8(input)
        val idBytes = ByteArray(idLen)
        readFully(input, idBytes)
        val id = String(idBytes, Charsets.US_ASCII)
        val wrappedLen = readU16(input)
        val wrapped = ByteArray(wrappedLen)
        readFully(input, wrapped)
        recipients[id] = wrapped
    }
    val noncePrefix = ByteArray(NONCE_PREFIX_LEN)
    readFully(input, noncePrefix)
    return Header(recipients, noncePrefix)
}

private fun readFully(input: InputStream, buf: ByteArray) {
    var off = 0
    while (off < buf.size) {
        val n = input.read(buf, off, buf.size - off)
        if (n < 0) throw IOException("truncated header")
        off += n
    }
}

private fun readU8(input: InputStream): Int {
    val b = input.read()
    if (b < 0) throw IOException("truncated header")
    return b
}

private fun readU16(input: InputStream): Int = (readU8(input) shl 8) or readU8(input)

/** Writes AES-GCM frames of [role] to [out] (positioned after the header), indexed from 0. */
class FrameWriter(private val out: OutputStream, private val key: EntryKey, private val role: Byte) {
    var frames: Long = 0
        private set

    fun write(plain: ByteArray) {
        val ct = key.encrypt(plain, role, frames)
        out.write(ByteBuffer.allocate(4).putInt(ct.size).array())
        out.write(ct)
        frames++
    }
}

/**
 * Reads AES-GCM frames of [role] from [input] (positioned after the header), in order from
 * index 0. Stops cleanly - without throwing - at the first frame that is short (truncated
 * write) or fails authentication (tampering, or frames out of order: the index is in the AAD).
 */
class FrameReader(private val input: InputStream, private val key: EntryKey, private val role: Byte) : Iterator<ByteArray> {
    private var index = 0L
    private var pending: ByteArray? = null
    private var done = false

    private fun fill() {
        if (pending != null || done) return
        val lenBuf = ByteArray(4)
        if (!tryReadFully(lenBuf)) {
            done = true
            return
        }
        val len = ByteBuffer.wrap(lenBuf).int
        if (len < 0) {
            done = true
            return
        }
        val ct = ByteArray(len)
        if (!tryReadFully(ct)) {
            done = true
            return
        }
        pending = try {
            key.decrypt(ct, role, index)
        } catch (e: AEADBadTagException) {
            done = true
            return
        } catch (e: javax.crypto.BadPaddingException) {
            done = true
            return
        }
        index++
    }

    private fun tryReadFully(buf: ByteArray): Boolean {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) return false
            off += n
        }
        return true
    }

    override fun hasNext(): Boolean {
        fill()
        return pending != null
    }

    override fun next(): ByteArray {
        if (!hasNext()) throw NoSuchElementException()
        val result = pending!!
        pending = null
        return result
    }
}
