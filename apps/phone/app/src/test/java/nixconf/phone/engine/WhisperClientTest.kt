package nixconf.phone.engine

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import nixconf.phone.audio.WavWriter
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class WhisperClientTest {
    @get:Rule val tmp = TemporaryFolder()

    private val server = MockWebServer().apply { start() }
    private val client = WhisperClient(OkHttpClient())
    private val url = server.url("/").toString().trimEnd('/')

    @After
    fun shutdown() = server.shutdown()

    private fun wav(): File = tmp.newFile("audio.wav").also {
        WavWriter(it).apply {
            write(ShortArray(1600) { i -> (i * 7).toShort() }, 1600)
            close()
        }
    }

    @Test
    fun probe_true_on_200_false_on_timeout() = runBlocking {
        server.enqueue(MockResponse().setBody("<html>whisper</html>"))
        assertTrue(client.probe(url))
        assertEquals("GET /", server.takeRequest().requestLine.substringBeforeLast(' '))

        server.enqueue(MockResponse().setBody("late").setHeadersDelay(2, TimeUnit.SECONDS))
        assertFalse(client.probe(url, timeoutMs = 300))

        server.enqueue(MockResponse().setResponseCode(503))
        assertFalse(client.probe(url))
    }

    // A socket-activated server answers once the model is loaded (1-3 s).
    @Test
    fun probe_waits_for_a_cold_server() = runBlocking {
        server.enqueue(MockResponse().setBody("warm").setHeadersDelay(2, TimeUnit.SECONDS))
        assertTrue(client.probe(url))
    }

    @Test
    fun probe_false_when_nothing_listens() = runBlocking {
        server.shutdown()
        assertFalse(client.probe(url))
    }

    @Test
    fun transcribe_sends_fields_and_parses_text() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"text":" Hello NixOS.\n"}"""))
        val text = client.transcribe(url, wav(), language = "en", prompt = "NixOS, flake.")
        assertEquals(" Hello NixOS.\n", text)

        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/inference", req.path)
        assertTrue(req.getHeader("Content-Type")!!.startsWith("multipart/form-data"))
        val body = req.body.readUtf8()
        fun field(name: String, value: String) =
            assertTrue("field $name=$value", Regex("""name="$name"\r\n(?:[^\r\n]+\r\n)*\r\n${Regex.escape(value)}\r\n""").containsMatchIn(body))
        field("language", "en")
        field("response_format", "json")
        field("prompt", "NixOS, flake.")
        field("temperature", "0.0")
        field("temperature_inc", "0.2")
        assertTrue(Regex("""name="file"; filename="audio.wav"""").containsMatchIn(body))
        assertTrue(body.contains("RIFF"))
    }

    @Test
    fun transcribe_throws_on_500() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(500).setBody("model failed"))
        try {
            client.transcribe(url, wav(), "en", "")
            fail("no exception")
        } catch (e: IOException) {
            assertTrue(e.message!!.contains("500"))
        }
    }

    @Test
    fun transcribe_throws_without_text() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"error":"busy"}"""))
        server.enqueue(MockResponse().setBody("not json"))
        val audio = wav()
        for (i in 1..2) {
            try {
                client.transcribe(url, audio, "en", "")
                fail("no exception")
            } catch (e: IOException) {
                // expected
            }
        }
    }
}
