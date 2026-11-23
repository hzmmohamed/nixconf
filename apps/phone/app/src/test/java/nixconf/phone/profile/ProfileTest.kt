package nixconf.phone.profile

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProfileTest {
    @get:Rule val tmp = TemporaryFolder()

    // Shape of the profile.json served by dictation-server (phone.profile).
    private val full = """
        {"version":1,
         "servers":["http://butternut:8178"],
         "defaultLanguage":"en","languages":["en","ar"],
         "prompt":"NixOS, Nix, flake.","keepDays":7,
         "localModel":{"name":"parakeet-tdt-0.6b-v2-int8","language":"en",
           "files":[
             {"name":"encoder.int8.onnx","size":652000000,"sha256":"${"a".repeat(64)}","url":"http://butternut:8180/models/parakeet/encoder.int8.onnx"},
             {"name":"decoder.int8.onnx","size":7000000,"sha256":"${"b".repeat(64)}","url":"http://butternut:8180/models/parakeet/decoder.int8.onnx"},
             {"name":"joiner.int8.onnx","size":1700000,"sha256":"${"c".repeat(64)}","url":"http://butternut:8180/models/parakeet/joiner.int8.onnx"},
             {"name":"tokens.txt","size":9000,"sha256":"${"d".repeat(64)}","url":"http://butternut:8180/models/parakeet/tokens.txt"}],
           "archive":{"url":"https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/x.tar.bz2","sha256":"${"e".repeat(64)}"}},
         "appUrl":"http://butternut:8180/app.json"}
    """.trimIndent()

    private fun profileJson(prompt: String) =
        """{"version":1,"servers":[],"defaultLanguage":"en","languages":["en"],"prompt":"$prompt","keepDays":7}"""

    @Test
    fun parses_full_profile() {
        val p = parseProfile(full)
        assertEquals(listOf("http://butternut:8178"), p.servers)
        assertEquals(listOf("en", "ar"), p.languages)
        assertEquals(4, p.localModel!!.files.size)
        assertEquals(652000000L, p.localModel!!.files[0].size)
        assertEquals("e".repeat(64), p.localModel!!.archive!!.sha256)
        assertEquals("http://butternut:8180/app.json", p.appUrl)
    }

    @Test
    fun ignores_unknown_keys() {
        val p = parseProfile("""{"version":1,"servers":["http://x:1"],"defaultLanguage":"en","languages":["en"],"prompt":"","keepDays":3,"future":{"a":1}}""")
        assertEquals(3, p.keepDays)
        assertNull(p.localModel)
        assertNull(p.appUrl)
    }

    @Test
    fun segmenting_fields_default_when_missing() {
        val old = parseProfile(full)
        assertEquals(550, old.pauseMs)
        assertEquals(25, old.maxSegmentSec)
        assertEquals(MODE_BATCH, old.mode)
        val p = parseProfile(full.replace("\"keepDays\":7,", "\"keepDays\":7,\"pauseMs\":700,\"maxSegmentSec\":20,\"mode\":\"stream\","))
        assertEquals(700, p.pauseMs)
        assertEquals(20, p.maxSegmentSec)
        assertEquals(MODE_STREAM, p.mode)
    }

    @Test(expected = UnsupportedProfile::class)
    fun rejects_future_version() {
        parseProfile("""{"version":2,"servers":"a new shape"}""")
    }

    @Test
    fun store_returns_cache_when_fetch_fails() {
        var now = 0L
        var fail = false
        val store = ProfileStore(tmp.root, { if (fail) throw IOException("offline") else profileJson("first") }, { now })
        assertEquals("first", store.refreshIfStale(URL)!!.prompt)

        now += 2 * 3_600_000
        fail = true
        assertEquals("first", store.refreshIfStale(URL)!!.prompt)
        assertEquals("first", store.cached()!!.prompt)
    }

    @Test
    fun store_keeps_cache_when_server_sends_future_version() {
        var now = 0L
        var body = profileJson("first")
        val store = ProfileStore(tmp.root, { body }, { now })
        store.refreshIfStale(URL)

        now += 2 * 3_600_000
        body = """{"version":2}"""
        assertEquals("first", store.refreshIfStale(URL)!!.prompt)
    }

    @Test
    fun store_without_cache_and_no_network_returns_null() {
        val store = ProfileStore(tmp.root, { throw IOException("offline") }, { 0L })
        assertNull(store.cached())
        assertNull(store.refreshIfStale(URL))
    }

    @Test
    fun store_skips_fetch_when_fresh() {
        var now = 1_000_000L
        var fetches = 0
        val store = ProfileStore(tmp.root, { fetches++; profileJson("p$fetches") }, { now })
        store.refreshIfStale(URL)
        now += 30 * 60_000
        assertEquals("p1", store.refreshIfStale(URL)!!.prompt)
        assertEquals(1, fetches)

        now += 31 * 60_000
        assertEquals("p2", store.refreshIfStale(URL)!!.prompt)
        assertEquals(2, fetches)
    }

    private companion object {
        const val URL = "http://butternut:8180/profile.json"
    }
}
