package nixconf.phone.diary

import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// One diary entry: metadata only, never the audio or the key. See
// constraints.md — this file (and its JSON) never carries the sealed
// audio or key material, only ids, times and (for typed/review entries)
// plain text that is itself written sealed by the entry store (Task 2).

/** How an entry was captured. Later plans add read_from_paper, imported_audio, imported_text, review. */
enum class Kind { spoken, typed }

/** Audio codec of the sealed recording; null for a typed entry (no audio). */
enum class Codec { opus, pcm_s16le }

/** Lifecycle of the recording itself (not the sealing or sync state). */
enum class State { Recording, Done, Interrupted }

/**
 * What the entry is about, when it isn't just "today": a single day (an entry written
 * about a past day) or a date range (e.g. a weekly review). Absent, it's about the day
 * it was recorded.
 */
@Serializable
sealed interface About {
    /** [date]: YYYY-MM-DD. */
    @Serializable
    @SerialName("day")
    data class Day(val date: String) : About

    /** [from]/[to]: YYYY-MM-DD, inclusive. */
    @Serializable
    @SerialName("range")
    data class Range(val from: String, val to: String) : About
}

/** A mood tap or words; [scale] 1..5, [source] "user" unless set elsewhere (e.g. a derived mood). */
@Serializable
data class Mood(
    val scale: Int? = null,
    val words: List<String> = emptyList(),
    val source: String = "user",
)

@Serializable
data class Entry(
    val id: String,
    /** UTC epoch ms. */
    val recordedAt: Long,
    /** IANA zone the entry was recorded in, kept so "today" stays correct across travel/DST. */
    val zone: String,
    val about: About? = null,
    val kind: Kind,
    /** null for a typed entry (no audio). */
    val codec: Codec?,
    /** Base64 Opus codec-specific data (CSD), set only when [codec] is opus. */
    val codecConfig: String? = null,
    val durationMs: Long = 0,
    val mood: Mood? = null,
    /** Typed/transcribed text; stored sealed like everything else, never read by this module alone. */
    val text: String? = null,
    val state: State = State.Recording,
    /** Removed from the normal list without deleting it. */
    val hidden: Boolean = false,
    val format: Int = 1,
)

/** JSON for entry metadata: forward-compatible (older readers ignore new fields the writer adds). */
val DiaryJson: Json = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    classDiscriminator = "type"
}

/**
 * Sort key for the diary list: by what the entry is *about* (its [About.Day]/[About.Range]
 * start date, or the local date of [Entry.recordedAt] in [Entry.zone] when [About] is absent),
 * then by [Entry.recordedAt]. Sorting entries by this key descending puts the most recent
 * "about" date first, newest-recorded first within a date.
 */
fun Entry.sortKey(): String {
    val date = when (val about = about) {
        is About.Day -> about.date
        is About.Range -> about.from
        null -> Instant.ofEpochMilli(recordedAt).atZone(ZoneId.of(zone)).toLocalDate().toString()
    }
    // recordedAt zero-padded to 19 digits (max digits in a positive Long) so string
    // comparison matches numeric comparison.
    return "$date|${recordedAt.toString().padStart(19, '0')}"
}
