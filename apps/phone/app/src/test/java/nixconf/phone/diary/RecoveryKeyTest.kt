package nixconf.phone.diary

import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test

class RecoveryKeyTest {
    companion object {
        private lateinit var rsa3072: KeyPair
        private lateinit var rsa2048: KeyPair

        @BeforeClass
        @JvmStatic
        fun generateKeys() {
            rsa3072 = KeyPairGenerator.getInstance("RSA").apply { initialize(3072) }.genKeyPair()
            rsa2048 = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.genKeyPair()
        }
    }

    private fun publicPem(key: PublicKey): String {
        val b64 = Base64.getEncoder().encodeToString(key.encoded)
        return "-----BEGIN PUBLIC KEY-----\n" + b64.chunked(64).joinToString("\n") + "\n-----END PUBLIC KEY-----\n"
    }

    private fun privatePem(key: java.security.PrivateKey): String {
        val b64 = Base64.getEncoder().encodeToString(key.encoded)
        return "-----BEGIN PRIVATE KEY-----\n" + b64.chunked(64).joinToString("\n") + "\n-----END PRIVATE KEY-----\n"
    }

    @Test
    fun parses_rsa3072_spki() {
        val result = RecoveryKey.parsePem(publicPem(rsa3072.public))
        assertTrue(result.isSuccess)
        assertEquals(rsa3072.public, result.getOrThrow())
    }

    @Test
    fun rejects_rsa2048() {
        val result = RecoveryKey.parsePem(publicPem(rsa2048.public))
        assertTrue(result.isFailure)
        assertEquals("needs RSA 3072 or larger", result.exceptionOrNull()?.message)
    }

    @Test
    fun rejects_private_key_pem() {
        val result = RecoveryKey.parsePem(privatePem(rsa3072.private))
        assertTrue(result.isFailure)
        assertEquals("this is a private key; paste the public one", result.exceptionOrNull()?.message)
    }

    @Test
    fun rejects_garbage() {
        val result = RecoveryKey.parsePem("not even remotely a PEM file")
        assertTrue(result.isFailure)
        assertEquals("not a public key (PEM)", result.exceptionOrNull()?.message)
    }

    @Test
    fun fingerprint_stable() {
        val a = RecoveryKey.fingerprint(rsa3072.public)
        val b = RecoveryKey.fingerprint(rsa3072.public)
        assertEquals(a, b)
        // 16 hex chars grouped by 4 with spaces: "ab12 cd34 ef56 7890".
        assertTrue("fingerprint '$a' doesn't match the expected shape", Regex("^[0-9a-f]{4} [0-9a-f]{4} [0-9a-f]{4} [0-9a-f]{4}$").matches(a))
        // Different keys fingerprint differently (not a hardcoded constant).
        assertTrue(a != RecoveryKey.fingerprint(rsa2048.public))
    }
}
