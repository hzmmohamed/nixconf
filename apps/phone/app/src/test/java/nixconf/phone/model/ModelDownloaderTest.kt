package nixconf.phone.model

import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import nixconf.phone.profile.Archive
import nixconf.phone.profile.LocalModel
import nixconf.phone.profile.ModelFile
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.apache.commons.compress.archivers.tar.TarArchiveEntry
import org.apache.commons.compress.archivers.tar.TarArchiveOutputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorOutputStream
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ModelDownloaderTest {
    @get:Rule val tmp = TemporaryFolder()

    // Serves [files] by path, honouring `Range: bytes=<n>-`; anything else is a 404.
    private val files = mutableMapOf<String, ByteArray>()
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val bytes = files[request.path] ?: return MockResponse().setResponseCode(404)
                val from = request.getHeader("Range")?.removePrefix("bytes=")?.removeSuffix("-")?.toInt()
                    ?: return MockResponse().setBody(Buffer().write(bytes))
                if (from >= bytes.size) return MockResponse().setResponseCode(416)
                return MockResponse().setResponseCode(206)
                    .setHeader("Content-Range", "bytes $from-${bytes.size - 1}/${bytes.size}")
                    .setBody(Buffer().write(bytes, from, bytes.size - from))
            }
        }
        start()
    }

    @After
    fun shutdown() = server.shutdown()

    private val names = listOf("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
    private val contents = names.associateWith { Random(it.hashCode()).nextBytes(20_000 + it.length * 100) }

    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun model(archive: Archive? = null, serve: Boolean = true): LocalModel {
        if (serve) contents.forEach { (n, b) -> files["/models/$n"] = b }
        return LocalModel(
            name = "parakeet",
            language = "en",
            files = names.map { n -> ModelFile(n, contents.getValue(n).size.toLong(), sha256(contents.getValue(n)), server.url("/models/$n").toString()) },
            archive = archive,
        )
    }

    private var unmetered = true
    private val downloader by lazy { ModelDownloader(OkHttpClient(), tmp.root, { unmetered }) }
    private val modelDir get() = File(tmp.root, "parakeet")

    private fun download(m: LocalModel, force: Boolean = false) = runBlocking { downloader.download(m, force) { _, _ -> } }

    @Test
    fun downloads_verifies_and_is_ready() {
        val m = model()
        assertFalse(downloader.isReady(m))
        val result = download(m)
        assertEquals(modelDir, result.getOrThrow())
        assertTrue(downloader.isReady(m))
        names.forEach { assertArrayEquals(contents[it], File(modelDir, it).readBytes()) }

        // Ready: nothing fetched again.
        val before = server.requestCount
        download(m).getOrThrow()
        assertEquals(before, server.requestCount)
    }

    @Test
    fun resumes_partial_file() {
        val m = model()
        val enc = contents.getValue("encoder.int8.onnx")
        modelDir.mkdirs()
        File(modelDir, "encoder.int8.onnx.part").writeBytes(enc.copyOf(8_000))

        download(m).getOrThrow()

        val first = server.takeRequest()
        assertEquals("/models/encoder.int8.onnx", first.path)
        assertEquals("bytes=8000-", first.getHeader("Range"))
        assertArrayEquals(enc, File(modelDir, "encoder.int8.onnx").readBytes())
        assertFalse(File(modelDir, "encoder.int8.onnx.part").exists())
        assertTrue(downloader.isReady(m))
    }

    @Test
    fun hash_mismatch_deletes_part_and_fails() {
        val m = model()
        files["/models/joiner.int8.onnx"] = Random(1).nextBytes(500)

        val result = download(m)
        assertTrue(result.exceptionOrNull() is HashMismatch)
        assertFalse(File(modelDir, "joiner.int8.onnx.part").exists())
        assertFalse(File(modelDir, "joiner.int8.onnx").exists())
        assertFalse(downloader.isReady(m))
    }

    @Test
    fun refuses_on_metered_unless_forced() {
        val m = model()
        unmetered = false
        assertTrue(download(m).exceptionOrNull() is NotOnWifi)
        assertEquals(0, server.requestCount)

        download(m, force = true).getOrThrow()
        assertTrue(downloader.isReady(m))
    }

    @Test
    fun part_file_never_counts_as_ready() {
        val m = model()
        modelDir.mkdirs()
        contents.forEach { (n, b) -> File(modelDir, "$n.part").writeBytes(b) }
        assertFalse(downloader.isReady(m))

        // A complete file without its verification record is not ready either.
        contents.forEach { (n, b) -> File(modelDir, n).writeBytes(b) }
        assertFalse(downloader.isReady(m))
    }

    @Test
    fun truncated_file_is_no_longer_ready() {
        val m = model()
        download(m).getOrThrow()
        File(modelDir, "tokens.txt").writeBytes(ByteArray(10))
        assertFalse(downloader.isReady(m))
    }

    @Test
    fun falls_back_to_archive() {
        val tar = ByteArrayOutputStream()
        TarArchiveOutputStream(BZip2CompressorOutputStream(tar)).use { out ->
            (contents + ("test_wavs/0.wav" to ByteArray(100))).forEach { (n, b) ->
                out.putArchiveEntry(TarArchiveEntry("sherpa-onnx-nemo-parakeet/$n").apply { size = b.size.toLong() })
                out.write(b)
                out.closeArchiveEntry()
            }
        }
        files["/release/model.tar.bz2"] = tar.toByteArray()
        val m = model(Archive(server.url("/release/model.tar.bz2").toString(), sha256(tar.toByteArray())), serve = false)

        download(m).getOrThrow()
        assertTrue(downloader.isReady(m))
        names.forEach { assertArrayEquals(contents[it], File(modelDir, it).readBytes()) }
        assertNull(modelDir.listFiles { f -> f.name.contains("tar") }?.firstOrNull())
    }

    @Test
    fun archive_hash_mismatch_fails() {
        files["/release/model.tar.bz2"] = ByteArray(1000)
        val m = model(Archive(server.url("/release/model.tar.bz2").toString(), "0".repeat(64)), serve = false)
        assertTrue(download(m).exceptionOrNull() is HashMismatch)
        assertFalse(downloader.isReady(m))
    }

    @Test
    fun unsafe_names_rejected_before_any_file_io() {
        val m = model()
        val outside = File(tmp.root, "evil")
        for (bad in listOf("../evil", "..", ".", "a/b", "a\\b", "", "x..y", "tokens.txt\u0000")) {
            val files = m.files.mapIndexed { i, f -> if (i == 0) f.copy(name = bad) else f }
            val result = download(m.copy(files = files))
            assertTrue(bad, result.exceptionOrNull() is UnsafeName)
            assertFalse(bad, downloader.isReady(m.copy(files = files)))
        }
        val result = download(m.copy(name = "../evil"))
        assertTrue(result.exceptionOrNull() is UnsafeName)
        assertFalse(downloader.isReady(m.copy(name = "../evil")))
        assertFalse(outside.exists())
        assertFalse(modelDir.exists())
        assertTrue(server.requestCount == 0)
    }
}
