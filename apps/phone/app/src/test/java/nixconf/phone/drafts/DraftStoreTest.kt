package nixconf.phone.drafts

import java.io.File
import nixconf.phone.audio.WavFiles
import nixconf.phone.audio.WavWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    private companion object {
        const val DAY = 24 * 3_600_000L
    }
}
