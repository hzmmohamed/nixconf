package nixconf.phone.diary

import java.security.SecureRandom
import java.util.Random

// ULID (https://github.com/ulid/spec): a 48-bit ms timestamp followed by
// 80 bits of randomness, Crockford base32, 26 chars, lexically sortable.
// Monotonic within the same millisecond: when nowMs repeats, the random
// part is incremented (as an 80-bit big-endian integer) instead of
// redrawn, so a burst of calls in one ms still sorts in call order.
object Ulid {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    private const val RANDOM_BYTES = 10 // 80 bits

    private var lastMs = -1L
    private var lastRandom = ByteArray(RANDOM_BYTES)

    @Synchronized
    fun next(nowMs: Long, random: Random = SecureRandom()): String {
        val randomBytes = if (nowMs == lastMs) {
            increment(lastRandom)
        } else {
            ByteArray(RANDOM_BYTES).also { random.nextBytes(it) }
        }
        lastMs = nowMs
        lastRandom = randomBytes
        return encodeTime(nowMs) + encodeRandom(randomBytes)
    }

    // Big-endian increment with carry; overflowing all 10 bytes needs more
    // than 2^80 calls in one millisecond, which never happens in practice.
    private fun increment(bytes: ByteArray): ByteArray {
        val out = bytes.copyOf()
        for (i in out.indices.reversed()) {
            val v = (out[i].toInt() and 0xFF) + 1
            out[i] = v.toByte()
            if (v <= 0xFF) break
        }
        return out
    }

    // 48 bits of time -> 10 base32 chars (50 bits available, top 2 unused).
    private fun encodeTime(ms: Long): String {
        val chars = CharArray(10)
        var t = ms
        for (i in 9 downTo 0) {
            chars[i] = ALPHABET[(t and 0x1F).toInt()]
            t = t ushr 5
        }
        return String(chars)
    }

    // 80 bits of randomness -> 16 base32 chars (exact fit, 5 bits each).
    private fun encodeRandom(bytes: ByteArray): String {
        val chars = CharArray(16)
        for (i in chars.indices) {
            chars[i] = ALPHABET[readBits(bytes, i * 5, 5)]
        }
        return String(chars)
    }

    private fun readBits(bytes: ByteArray, startBit: Int, count: Int): Int {
        var result = 0
        for (i in 0 until count) {
            val bitIndex = startBit + i
            val byteIndex = bitIndex / 8
            val bitInByte = 7 - (bitIndex % 8)
            val bit = if (byteIndex < bytes.size) (bytes[byteIndex].toInt() shr bitInByte) and 1 else 0
            result = (result shl 1) or bit
        }
        return result
    }
}
