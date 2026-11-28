package nixconf.phone.diary

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Test

// Golden fixture for the offline Python recovery tool (apps/phone/tools/diary_recover.py):
// a real entry written through EntryStore (Task 3), so its bytes are exactly what the
// phone produces, then opened here with the *recovery* recipient to prove the on-disk
// format documented in EntryCipher.kt is what the Python tool must parse.
//
// generate_fixture runs on every CI push (no local Gradle - see constraints.md) and writes
// a fresh fixture to build/diary-golden/; that is NOT what golden_matches_format reads.
// The committed fixture under src/test/resources/diary/golden/ is a frozen copy of one such
// run's output, downloaded from the CI artifact and committed by hand; refresh it the same
// way if the sealed format ever changes.
class GoldenFixtureTest {

    @Test
    fun golden_matches_format() {
        val goldenDir = File(javaClass.classLoader.getResource("diary/golden")!!.toURI())
        val recoveryKey = loadPrivateKeyPem(File(goldenDir, "recovery_test_key.pem"))
        val entryDir = goldenDir.listFiles { f -> f.isDirectory }!!.single()

        val metaBytes = readRoleFrames(File(entryDir, "meta.pdy"), recoveryKey, "recovery:", ROLE_META)
        assertArrayEquals(File(goldenDir, "expected_meta.json").readBytes(), metaBytes)

        val audioBytes = readRoleFrames(File(entryDir, "audio.pdy"), recoveryKey, "recovery:", ROLE_AUDIO)
        assertArrayEquals(File(goldenDir, "expected_frames.bin").readBytes(), audioBytes)
    }

    /**
     * Writes a fresh fixture to build/diary-golden/ (see the class comment above): a 1s
     * 440 Hz sine as pcm_s16le in 2 frames, plus a mood. Not what [golden_matches_format]
     * reads - this is the generator CI uploads so the fixture can be refreshed by hand.
     */
    @Test
    fun generate_fixture() {
        val deviceKeys = KeyPairGenerator.getInstance("RSA").apply { initialize(3072) }.genKeyPair()
        val recoveryKeys = KeyPairGenerator.getInstance("RSA").apply { initialize(3072) }.genKeyPair()
        val recipients = listOf(
            Recipient("device:diary-device-v1", deviceKeys.public),
            Recipient("recovery:test-key-v1", recoveryKeys.public),
        )

        val outDir = File(File(System.getProperty("user.dir"), "build"), "diary-golden")
        outDir.deleteRecursively()
        outDir.mkdirs()

        val store = EntryStore(outDir, { recipients }, { 1_795_000_000_000L })
        val open = store.create(Kind.spoken, Codec.pcm_s16le, "Africa/Cairo")
        open.appendAudio(sineChunk(startSample = 0, numSamples = 8000))
        open.appendAudio(sineChunk(startSample = 8000, numSamples = 8000))
        open.update { it.copy(mood = Mood(4, listOf("calm", "هادي"))) }
        open.finish(durationMs = 1000)
        val id = open.entry.id

        val entryDir = File(outDir, id)
        val metaBytes = readRoleFrames(File(entryDir, "meta.pdy"), deviceKeys.private, "device:", ROLE_META)
        val audioBytes = readRoleFrames(File(entryDir, "audio.pdy"), deviceKeys.private, "device:", ROLE_AUDIO)
        File(outDir, "expected_meta.json").writeBytes(metaBytes)
        File(outDir, "expected_frames.bin").writeBytes(audioBytes)
        File(outDir, "recovery_test_key.pem").writeText(pemFor(recoveryKeys.private))
        File(outDir, "README.md").writeText(
            "# Test-only key\n\n" +
                "recovery_test_key.pem is a disposable RSA-3072 private key generated only for\n" +
                "this golden fixture (GoldenFixtureTest.generate_fixture). It wraps nothing real;\n" +
                "never use it outside tests.\n",
        )
    }

    private fun sineChunk(startSample: Int, numSamples: Int, sampleRate: Int = 16000, freq: Double = 440.0): ByteArray {
        val buf = ByteBuffer.allocate(numSamples * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until numSamples) {
            val t = (startSample + i).toDouble() / sampleRate
            val sample = (Math.sin(2 * Math.PI * freq * t) * 16384.0).toInt().toShort()
            buf.putShort(sample)
        }
        return buf.array()
    }

    /** Opens [file] with [privateKey]/[idPrefix] and concatenates every [role] frame's plaintext. */
    private fun readRoleFrames(file: File, privateKey: PrivateKey, idPrefix: String, role: Byte): ByteArray =
        FileInputStream(file).use { input ->
            val header = readHeader(input)
            val key = EntryKey.open(header, privateKey, idPrefix)
            val out = ByteArrayOutputStream()
            FrameReader(input, key, role).asSequence().forEach { out.write(it) }
            out.toByteArray()
        }

    private fun pemFor(key: PrivateKey): String {
        val b64 = Base64.getEncoder().encodeToString(key.encoded)
        return "-----BEGIN PRIVATE KEY-----\n" + b64.chunked(64).joinToString("\n") + "\n-----END PRIVATE KEY-----\n"
    }

    private fun loadPrivateKeyPem(file: File): PrivateKey {
        val b64 = file.readText().lineSequence().filterNot { it.startsWith("-----") }.joinToString("")
        val bytes = Base64.getDecoder().decode(b64)
        return KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(bytes))
    }
}
