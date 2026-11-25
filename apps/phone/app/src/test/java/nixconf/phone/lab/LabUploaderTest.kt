package nixconf.phone.lab

import kotlinx.coroutines.runBlocking
import nixconf.phone.audio.WavWriter
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import nixconf.phone.drafts.SegmentText
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
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

    // Past the undo window: only settled drafts go up.
    private fun settle() {
        now += LabUploader.SETTLE_MS + 1
    }

    @Test
    fun uploads_files_then_done_and_marks() = runBlocking {
        val d = delivered()
        settle()
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
        settle()
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
        settle()
        server.shutdown()
        assertEquals(0, uploader.uploadAll(lab))
        assertNull(drafts.load(d.id)!!.uploadedMs)
    }

    @Test
    fun a_fresh_delivery_waits_for_the_undo_window() = runBlocking {
        delivered()
        assertEquals(0, uploader.uploadAll(lab))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun undone_during_upload_stays_cancelled() = runBlocking {
        val d = delivered()
        settle()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                // The user taps Undo while the draft is on its way.
                if (request.method == "POST") drafts.update(drafts.load(d.id)!!.copy(status = DraftStatus.CANCELLED))
                return MockResponse().setResponseCode(if (request.method == "POST") 200 else 204)
            }
        }
        uploader.uploadAll(lab)
        val after = drafts.load(d.id)!!
        assertEquals(DraftStatus.CANCELLED, after.status)
        assertNull(after.uploadedMs)
    }

    @Test
    fun a_rejected_draft_is_skipped_not_blocking() = runBlocking {
        val bad = delivered("first")
        now += 1000
        val good = delivered("second")
        settle()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when {
                request.path!!.contains(bad.id) && request.method == "POST" -> MockResponse().setResponseCode(400)
                request.method == "POST" -> MockResponse().setResponseCode(200)
                else -> MockResponse().setResponseCode(204)
            }
        }
        assertEquals(1, uploader.uploadAll(lab))
        assertNull(drafts.load(bad.id)!!.uploadedMs)
        assertEquals(now, drafts.load(good.id)!!.uploadedMs)
    }

    @Test
    fun nothing_to_upload_makes_no_requests() = runBlocking {
        drafts.create("en") // pending
        assertEquals(0, uploader.uploadAll(lab))
        assertEquals(0, server.requestCount)
    }
}
