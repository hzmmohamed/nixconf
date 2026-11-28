package nixconf.phone.diary

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EntryTest {
    @Test
    fun json_roundtrip_with_about_range() {
        val entry = Entry(
            id = "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            recordedAt = 1_700_000_000_000L,
            zone = "Africa/Cairo",
            about = About.Range("2024-01-01", "2024-03-31"),
            kind = Kind.spoken,
            codec = Codec.opus,
            mood = Mood(4, listOf("calm")),
        )
        val json = DiaryJson.encodeToString(Entry.serializer(), entry)
        assertTrue(json.contains("\"type\":\"range\""))
        val decoded = DiaryJson.decodeFromString(Entry.serializer(), json)
        assertEquals(entry, decoded)
    }

    @Test
    fun utf8_arabic_roundtrip() {
        val entry = Entry(
            id = "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            recordedAt = 1_700_000_000_000L,
            zone = "Africa/Cairo",
            kind = Kind.typed,
            codec = null,
            mood = Mood(null, listOf("هادي", "light")),
            text = "ابني flake جديد",
        )
        val bytes = DiaryJson.encodeToString(Entry.serializer(), entry).toByteArray(Charsets.UTF_8)
        val decoded = DiaryJson.decodeFromString(Entry.serializer(), String(bytes, Charsets.UTF_8))
        assertEquals(entry, decoded)
    }

    @Test
    fun unknown_fields_ignored() {
        val raw = """
            {"id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","recordedAt":1700000000000,"zone":"Africa/Cairo",
             "kind":"spoken","codec":"opus","future":1}
        """.trimIndent()
        val decoded = DiaryJson.decodeFromString(Entry.serializer(), raw)
        assertEquals("01ARZ3NDEKTSV4RRFFQ69G5FAV", decoded.id)
    }

    @Test
    fun sort_by_about_then_recorded() {
        val entry2024 = Entry(
            id = "A",
            recordedAt = epochMs(2026, 11, 28, 9, 0, "UTC"),
            zone = "UTC",
            about = About.Day("2024-05-01"),
            kind = Kind.spoken,
            codec = Codec.opus,
        )
        val entry27th = Entry(
            id = "B",
            recordedAt = epochMs(2026, 11, 27, 9, 0, "UTC"),
            zone = "UTC",
            kind = Kind.spoken,
            codec = Codec.opus,
        )
        val entry28thCairo = Entry(
            id = "C",
            recordedAt = epochMs(2026, 11, 28, 10, 0, "Africa/Cairo"),
            zone = "Africa/Cairo",
            kind = Kind.spoken,
            codec = Codec.opus,
        )
        val sorted = listOf(entry2024, entry27th, entry28thCairo).sortedByDescending { it.sortKey() }
        assertEquals(listOf("C", "B", "A"), sorted.map { it.id })
    }

    private fun epochMs(year: Int, month: Int, day: Int, hour: Int, minute: Int, zone: String): Long =
        java.time.ZonedDateTime.of(year, month, day, hour, minute, 0, 0, java.time.ZoneId.of(zone))
            .toInstant().toEpochMilli()
}
