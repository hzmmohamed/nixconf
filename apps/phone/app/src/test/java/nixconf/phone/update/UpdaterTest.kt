package nixconf.phone.update

import java.io.File
import java.security.MessageDigest
import kotlin.random.Random
import kotlinx.coroutines.runBlocking
import nixconf.phone.model.HashMismatch
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class UpdaterTest {
    @get:Rule val tmp = TemporaryFolder()

    private val files = mutableMapOf<String, ByteArray>()
    private val server = MockWebServer().apply {
        dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val bytes = files[request.path] ?: return MockResponse().setResponseCode(404)
                return MockResponse().setBody(Buffer().write(bytes))
            }
        }
        start()
    }

    @After
    fun shutdown() = server.shutdown()

    private val apk = Random(1).nextBytes(50_000)
    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private val installed = mutableListOf<File>()
    private fun updater() = Updater(OkHttpClient(), tmp.newFolder("updates")) { installed += it }

    // app.json as `phone-app publish` writes it.
    private fun publish(versionCode: Int, sha256: String = sha256(apk), url: String? = null): String {
        files["/app/nixconf-phone-$versionCode.apk"] = apk
        val apkUrl = url ?: server.url("/app/nixconf-phone-$versionCode.apk").toString()
        files["/app.json"] =
            """{"versionCode":$versionCode,"versionName":"abc1234","url":"$apkUrl","sha256":"$sha256"}""".toByteArray()
        return server.url("/app.json").toString()
    }

    @Test
    fun newer_release_offered() = runBlocking {
        val release = updater().check(publish(12), currentVersionCode = 11)
        assertNotNull(release)
        assertEquals(12, release!!.versionCode)
        assertEquals("abc1234", release.versionName)
    }

    @Test
    fun same_or_older_ignored() = runBlocking {
        val appUrl = publish(12)
        val u = updater()
        assertNull(u.check(appUrl, currentVersionCode = 12))
        assertNull(u.check(appUrl, currentVersionCode = 13))
    }

    @Test
    fun relative_apk_url_resolved_against_app_json() = runBlocking {
        val release = updater().check(publish(12, url = "app/nixconf-phone-12.apk"), currentVersionCode = 1)!!
        assertEquals(server.url("/app/nixconf-phone-12.apk").toString(), release.url)
    }

    @Test
    fun verified_download_is_the_apk() = runBlocking {
        val u = updater()
        val file = u.downloadVerified(u.check(publish(12), 1)!!)
        assertArrayEquals(apk, file.readBytes())
        u.install(file)
        assertEquals(listOf(file), installed)
    }

    @Test
    fun bad_hash_rejected() = runBlocking {
        val u = updater()
        val release = u.check(publish(12, sha256 = "0".repeat(64)), 1)!!
        try {
            u.downloadVerified(release)
            fail("expected HashMismatch")
        } catch (e: HashMismatch) {
            // expected
        }
        val left = tmp.root.resolve("updates").listFiles().orEmpty()
        assertTrue("nothing left behind: ${left.toList()}", left.isEmpty())
        assertTrue(installed.isEmpty())
    }

    @Test
    fun unreachable_app_json_throws() = runBlocking {
        try {
            updater().check(server.url("/missing.json").toString(), 1)
            fail("expected an IOException")
        } catch (e: java.io.IOException) {
            assertFalse(e is HashMismatch)
        }
    }
}
