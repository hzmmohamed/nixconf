package nixconf.phone.lab

import kotlinx.coroutines.runBlocking
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import nixconf.phone.drafts.SegmentText
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LabUploaderTest {
    @get:Rule val tmp = TemporaryFolder()

    private val server = MockWebServer().apply { start() }
    private val lab = server.url("/").toString().trimEnd('/')
    private var now = 1_795_000_000_000L
    private val drafts by lazy { DraftStore(tmp.root, { now }) }
    private val uploader by lazy { LabUploader(OkHttpClient(), drafts) { now } }

    @After
    fun shutdown() = server.shutdown()

    private fun delivered(text: String = "an invented line"): Draft {
        val d = drafts.create("en")
        WavWriter(d.audio).apply {
            write(ShortArray(1600), 1600)
            close()
        }
        drafts.addSegment(d, SegmentText(0, 0, 1600, text))
        return d.copy(status = DraftStatus.DELIVERED, text = text).also(drafts::update)
    }

    @Test
    fun uploads_files_then_done_and_marks() = runBlocking {
        val d = delivered()
        repeat(3) { server.enqueue(MockResponse().setResponseCode(204)) }
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        assertEquals(1, uploader.uploadAll(lab))
        val reqs = List(4) { server.takeRequest() }
        assertEquals(
            listOf(
                "PUT /inbox/phone/${d.id}/meta.json",
                "PUT /inbox/phone/${d.id}/segments.jsonl",
                "PUT /inbox/phone/${d.id}/audio.wav",
                "POST /inbox/phone/${d.id}/done",
            ),
            reqs.map { "${it.method} ${it.path}" },
        )
        assertEquals(d.audio.length(), reqs[2].bodySize)
        assertEquals(now, drafts.load(d.id)!!.uploadedMs)
    }

    @Test
    fun stops_at_first_failure() = runBlocking {
        val a = delivered("first")
        now += 1000
        val b = delivered("second")
        repeat(3) { server.enqueue(MockResponse().setResponseCode(204)) }
        server.enqueue(MockResponse().setResponseCode(500))
        assertEquals(0, uploader.uploadAll(lab))
        assertEquals(4, server.requestCount)
        assertNull(drafts.load(a.id)!!.uploadedMs)
        assertNull(drafts.load(b.id)!!.uploadedMs)
    }

    @Test
    fun unreachable_lab_uploads_nothing() = runBlocking {
        val d = delivered()
        server.shutdown()
        assertEquals(0, uploader.uploadAll(lab))
        assertNull(drafts.load(d.id)!!.uploadedMs)
    }

    @Test
    fun nothing_to_upload_makes_no_requests() = runBlocking {
        drafts.create("en") // pending
        assertEquals(0, uploader.uploadAll(lab))
        assertEquals(0, server.requestCount)
    }
}
