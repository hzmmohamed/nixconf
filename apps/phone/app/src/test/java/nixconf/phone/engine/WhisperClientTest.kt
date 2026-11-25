package nixconf.phone.engine

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.SegmentConf
import nixconf.phone.drafts.WordConf
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
        val result = client.transcribe(url, wav(), language = "en", prompt = "NixOS, flake.")
        assertEquals(Transcript(" Hello NixOS.\n", null), result)

        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/inference", req.path)
        assertTrue(req.getHeader("Content-Type")!!.startsWith("multipart/form-data"))
        val body = req.body.readUtf8()
        fun field(name: String, value: String) =
            assertTrue("field $name=$value", Regex("""name="$name"\r\n(?:[^\r\n]+\r\n)*\r\n${Regex.escape(value)}\r\n""").containsMatchIn(body))
        field("language", "en")
        field("response_format", "verbose_json")
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

    // The shape whisper.cpp's server answers with verbose_json (checked on butternut, 2026-11-25); invented words.
    private val verbose = """
        {"task":"transcribe","language":"english","duration":2.0,"text":" an example here",
         "detected_language":"english","detected_language_probability":0.97,
         "segments":[
          {"id":0,"text":" an example","start":0.0,"end":1.0,"temperature":0.0,"avg_logprob":-0.2,"no_speech_prob":0.01,
           "words":[{"word":" an","start":0.0,"end":0.2,"t_dtw":-1,"probability":0.99},
                    {"word":" example","start":0.2,"end":1.0,"t_dtw":-1,"probability":0.6}]},
          {"id":1,"text":" here","start":1.0,"end":2.0,"temperature":0.0,"avg_logprob":-0.7,"no_speech_prob":0.2,
           "words":[{"word":" here","start":1.0,"end":2.0,"t_dtw":-1,"probability":0.4}]}]}
    """.trimIndent()

    @Test
    fun transcribe_reads_verbose_json_confidence() = runBlocking {
        server.enqueue(MockResponse().setBody(verbose))
        val result = client.transcribe(url, wav(), "en", "")
        assertEquals(" an example here", result.text)
        assertEquals(
            SegmentConf(
                avgLogprob = -0.7,
                noSpeechProb = 0.2,
                words = listOf(WordConf(" an", 0.99, 0.0, 0.2), WordConf(" example", 0.6, 0.2, 1.0), WordConf(" here", 0.4, 1.0, 2.0)),
                lang = "english",
                langP = 0.97,
            ),
            result.conf,
        )
    }

    @Test
    fun transcribe_plain_json_has_no_conf() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"text":"hi","segments":[]}"""))
        assertEquals(Transcript("hi", null), client.transcribe(url, wav(), "en", ""))
    }

    @Test
    fun prompt_sha_is_12_hex_of_sha256() {
        // sha256("NixOS, Sway.") — the same value dictate-stream's prompt_sha gives.
        assertEquals(
            java.security.MessageDigest.getInstance("SHA-256").digest("NixOS, Sway.".toByteArray())
                .joinToString("") { "%02x".format(it) }.take(12),
            promptSha("NixOS, Sway."),
        )
        assertEquals(12, promptSha("").length)
    }
}
