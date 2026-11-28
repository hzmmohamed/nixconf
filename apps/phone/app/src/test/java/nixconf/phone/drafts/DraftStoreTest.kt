package nixconf.phone.drafts

import java.io.File
import nixconf.phone.audio.WavFiles
import nixconf.phone.audio.WavWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DraftStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private var now = 1_795_000_000_000L
    private val store by lazy { DraftStore(tmp.root, { now }) }

    @Test
    fun create_then_pending_lists_it() {
        val d = store.create("en")
        assertTrue(Regex("""\d{8}_\d{6}-[0-9a-f]{4}""").matches(d.id))
        assertEquals(DraftStatus.PENDING, d.status)
        assertEquals("en", d.language)
        assertEquals(now, d.createdMs)
        assertTrue(File(d.dir, "meta.json").isFile)
        assertEquals(listOf(d), store.pending())
    }

    @Test
    fun pending_is_oldest_first_and_skips_finished() {
        val a = store.create("en")
        now += 1000
        val b = store.create("ar")
        now += 1000
        val c = store.create("en")
        store.update(b.copy(status = DraftStatus.DELIVERED))
        assertEquals(listOf(a.id, c.id), store.pending().map { it.id })
    }

    @Test
    fun delivered_and_cancelled_pruned_after_keepDays_pending_kept() {
        val pending = store.create("en")
        val delivered = store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED, text = "hi")) }
        val cancelled = store.create("en").also { store.update(it.copy(status = DraftStatus.CANCELLED)) }

        now += 6 * DAY
        store.prune(keepDays = 7)
        assertTrue(delivered.dir.exists())

        now += 2 * DAY
        store.prune(keepDays = 7)
        assertTrue(pending.dir.exists())
        assertFalse(delivered.dir.exists())
        assertFalse(cancelled.dir.exists())
        assertEquals(listOf(pending.id), store.pending().map { it.id })
    }

    @Test
    fun keepDays_counts_from_when_the_draft_finished() {
        val d = store.create("en")
        now += 10 * DAY
        store.update(d.copy(status = DraftStatus.DELIVERED, text = "late retry"))
        now += DAY
        store.prune(keepDays = 7)
        assertTrue(d.dir.exists())
    }

    @Test
    fun meta_survives_reload() {
        val d = store.create("ar")
        val filled = d.copy(engine = "butternut", text = "مرحبا \"quoted\"", error = "timeout")
        store.update(filled)
        assertEquals(filled, DraftStore(tmp.root, { now }).load(d.id))
    }

    @Test
    fun load_missing_returns_null() {
        assertNull(store.load("20260101_000000-0000"))
    }

    @Test
    fun load_repairs_audio_of_pending_draft() {
        val d = store.create("en")
        WavWriter(d.audio).apply {
            write(ShortArray(1600), 1600)
            flush()
        }
        store.load(d.id)
        assertFalse(WavFiles.repair(d.audio))
        assertEquals(1600, WavFiles.readSamples(d.audio).size)
    }

    @Test
    fun active_draft_skipped_before_load_its_header_untouched() {
        val other = store.create("en")
        WavWriter(other.audio).apply {
            write(ShortArray(800), 800)
            flush()
        }
        val active = store.create("en")
        val writer = WavWriter(active.audio)
        writer.write(ShortArray(1600), 1600)
        writer.flush()

        assertEquals(listOf(other.id), store.pending(isActive = { it == active.id }).map { it.id })
        // Still being written: header sizes left at 0 for close() to fill in.
        assertEquals(0, dataSize(active.audio))
        assertEquals(800 * 2, dataSize(other.audio)) // repaired: not being written

        writer.write(ShortArray(400), 400)
        writer.close()
        assertEquals(2000, WavFiles.readSamples(active.audio).size)
    }

    @Test
    fun audio_without_readable_meta_is_listed_as_pending() {
        val lost = store.create("ar")
        WavWriter(lost.audio).apply {
            write(ShortArray(1600), 1600)
            close()
        }
        File(lost.dir, "meta.json").delete()
        val garbled = store.create("en")
        WavWriter(garbled.audio).apply {
            write(ShortArray(1600), 1600)
            close()
        }
        File(garbled.dir, "meta.json").writeText("{\"status\":")
        // No audio either: nothing to keep.
        val empty = store.create("en")
        File(empty.dir, "meta.json").delete()

        val listed = store.pending()
        assertEquals(setOf(lost.id, garbled.id), listed.map { it.id }.toSet())
        for (d in listed) {
            assertEquals(DraftStatus.PENDING, d.status)
            assertEquals(now / 1000 * 1000, d.createdMs) // from the id (second precision)
            assertNull(d.text)
        }
        // A retry can still write its meta.
        val restored = listed.first { it.id == lost.id }.copy(text = "hi")
        store.update(restored)
        assertEquals("hi", store.load(lost.id)!!.text)
    }

    private fun dataSize(wav: File): Int = java.io.RandomAccessFile(wav, "r").use {
        it.seek(40)
        Integer.reverseBytes(it.readInt())
    }

    @Test
    fun segments_appended_in_order_and_torn_line_skipped() {
        val d = store.create("en")
        assertTrue(store.segments(d).isEmpty())
        store.addSegment(d, SegmentText(0, 0, 16000, "Hello there.", "http://butternut:8178"))
        store.addSegment(d, SegmentText(1, 20000, 36000, "how are you", "local"))
        File(d.dir, "segments.jsonl").appendText("{\"i\":2,\"start\":40") // killed mid-write
        assertEquals(listOf("Hello there.", "how are you"), store.segments(d).map { it.text })
        assertEquals("local", store.segments(d)[1].engine)
        // The draft itself is unchanged: still pending, no text (a retry transcribes the WAV).
        assertNull(store.load(d.id)!!.text)
    }

    private companion object {
        const val DAY = 24 * 3_600_000L
    }

    @Test
    fun create_records_app_tier_and_prompt_hash() {
        val d = store.create("en", "com.example.chat", TIER_WORK, "abc123def456")
        val loaded = store.load(d.id)!!
        assertEquals("com.example.chat", loaded.app)
        assertEquals(TIER_WORK, loaded.tier)
        assertEquals("abc123def456", loaded.promptSha)
        val meta = File(d.dir, "meta.json").readText()
        assertTrue(meta, meta.contains("\"origin\":\"phone\""))
        assertTrue(meta, meta.contains("\"tier\":\"work\""))
    }

    @Test
    fun default_tier_is_written_as_personal() {
        val d = store.create("en")
        assertTrue(File(d.dir, "meta.json").readText().contains("\"tier\":\"personal\""))
    }

    @Test
    fun meta_without_tier_loads_as_personal() {
        val dir = File(tmp.root, "20261101_120000-abcd").apply { mkdirs() }
        File(dir, "meta.json").writeText(
            """{"status":"delivered","createdMs":1,"updatedMs":2,"language":"en","text":"old"}""",
        )
        val d = store.load(dir.name)!!
        assertEquals(TIER_PERSONAL, d.tier)
        assertNull(d.app)
        assertEquals("old", d.text)
    }

    @Test
    fun segment_confidence_round_trips() {
        val d = store.create("en")
        val conf = SegmentConf(
            avgLogprob = -0.4,
            noSpeechProb = 0.02,
            words = listOf(WordConf(" an", 0.9, 0.0, 0.2), WordConf(" example", 0.4, 0.2, 0.8)),
            lang = "english",
            langP = 0.97,
        )
        store.addSegment(d, SegmentText(0, 0, 16000, "an example", "remote", conf))
        store.addSegment(d, SegmentText(1, 16000, 32000, "more", "local"))
        val segs = store.segments(d)
        assertEquals(conf, segs[0].conf)
        assertNotNull(segs[0].conf)
        assertNull(segs[1].conf)
    }

    // --- training lab uploads ---

    @Test
    fun to_upload_lists_delivered_not_uploaded() {
        store.create("en") // pending
        store.create("en").also { store.update(it.copy(status = DraftStatus.CANCELLED)) }
        now += 1000
        val delivered = store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED, text = "a")) }
        store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED, text = "b", uploadedMs = 5)) }
        assertEquals(listOf(delivered.id), store.toUpload().map { it.id })
    }

    @Test
    fun uploaded_round_trips() {
        val d = store.create("en")
        store.update(d.copy(status = DraftStatus.DELIVERED, uploadedMs = 1234))
        assertEquals(1234L, store.load(d.id)!!.uploadedMs)
    }

    @Test
    fun prune_keeps_unsent_delivered_until_unsent_days() {
        val day = 24L * 3_600_000
        val unsent = store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED)) }
        val sent = store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED, uploadedMs = 1)) }
        now += 10 * day
        store.prune(keepDays = 7, unsentDays = 30)
        assertTrue(File(tmp.root, unsent.id).exists())
        assertFalse(File(tmp.root, sent.id).exists())
        now += 21 * day
        store.prune(keepDays = 7, unsentDays = 30)
        assertFalse(File(tmp.root, unsent.id).exists())
    }

    @Test
    fun prune_without_lab_ignores_upload_state() {
        val day = 24L * 3_600_000
        val unsent = store.create("en").also { store.update(it.copy(status = DraftStatus.DELIVERED)) }
        now += 10 * day
        store.prune(keepDays = 7)
        assertFalse(File(tmp.root, unsent.id).exists())
    }

    @Test
    fun files_are_meta_segments_and_audio() {
        val d = store.create("en")
        WavWriter(d.audio).close()
        assertEquals(listOf("meta.json", "audio.wav"), store.files(d).map { it.name })
        store.addSegment(d, SegmentText(0, 0, 10, "x"))
        assertEquals(listOf("meta.json", "segments.jsonl", "audio.wav"), store.files(d).map { it.name })
    }
}
