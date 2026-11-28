package nixconf.phone.drafts

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.random.Random
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import nixconf.phone.audio.WavFiles

// Every recording is a draft: <root>/<id>/{audio.wav,meta.json}, plus
// segments.jsonl when it was transcribed segment by segment (one line per
// segment, appended as each lands: a killed app keeps what was heard). A
// draft stays PENDING until its text reached a field (DELIVERED) or the user
// threw it away (CANCELLED); only those two are pruned, so audio is never
// lost: a draft whose meta.json is missing or unreadable but has audio is
// PENDING.
/** Privacy tier (training lab): a work draft may be analysed by Claude. */
const val TIER_WORK = "work"

/** Privacy tier: only the user's own machines read it. The default, and what any unknown value means. */
const val TIER_PERSONAL = "personal"

@Serializable
enum class DraftStatus {
    @SerialName("pending") PENDING,
    @SerialName("delivered") DELIVERED,
    @SerialName("cancelled") CANCELLED,
}

data class Draft(
    val id: String,
    val dir: File,
    val status: DraftStatus,
    val createdMs: Long,
    val language: String,
    val engine: String?,
    val text: String?,
    val error: String?,
    /** The app the text was for (package name), null if unknown. */
    val app: String? = null,
    val tier: String = TIER_PERSONAL,
    /** First 12 hex of the SHA-256 of the Whisper prompt in use. */
    val promptSha: String? = null,
    /** When the training lab received it (null: not yet). */
    val uploadedMs: Long? = null,
) {
    val audio: File get() = File(dir, "audio.wav")
}

/**
 * One line of segments.jsonl: segment [i] (samples [start, end) of audio.wav), its text, who
 * transcribed it and how sure Whisper was ([conf]; null for Parakeet or a plain-json server).
 */
@Serializable
data class SegmentText(
    val i: Int,
    val start: Long,
    val end: Long,
    val text: String,
    val engine: String? = null,
    val conf: SegmentConf? = null,
)

/** Whisper's verbose_json confidence for one request: the worst segment's scores, every word, the detected language. */
@Serializable
data class SegmentConf(
    val avgLogprob: Double,
    val noSpeechProb: Double,
    val words: List<WordConf> = emptyList(),
    val lang: String? = null,
    val langP: Double? = null,
)

/** A word, its probability and its time in seconds from the start of the segment's audio. */
@Serializable
data class WordConf(val w: String, val p: Double, val start: Double, val end: Double)

// meta.json; updatedMs (last status/text change) is what keepDays counts from.
// tier and origin are always written: the lab reads them without defaults.
@OptIn(ExperimentalSerializationApi::class)
@Serializable
private data class Meta(
    val status: DraftStatus,
    val createdMs: Long,
    val updatedMs: Long,
    val language: String,
    val engine: String? = null,
    val text: String? = null,
    val error: String? = null,
    val app: String? = null,
    @EncodeDefault val tier: String = TIER_PERSONAL,
    val promptSha: String? = null,
    @EncodeDefault val origin: String = ORIGIN_PHONE,
    val uploadedMs: Long? = null,
)

private const val ORIGIN_PHONE = "phone"

class DraftStore(private val root: File, private val clock: () -> Long) {
    private val json = Json { ignoreUnknownKeys = true }
    private val idTime = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss").withZone(ZoneId.systemDefault())

    fun create(language: String, app: String? = null, tier: String = TIER_PERSONAL, promptSha: String? = null): Draft {
        val now = clock()
        val stamp = idTime.format(Instant.ofEpochMilli(now))
        var dir: File
        do {
            dir = File(root, "$stamp-%04x".format(Random.nextInt(0x10000)))
        } while (dir.exists())
        if (!dir.mkdirs()) throw IOException("cannot create $dir")
        val draft = Draft(dir.name, dir, DraftStatus.PENDING, now, language, null, null, null, app, tier, promptSha)
        update(draft)
        return draft
    }

    /** Writes [draft]'s meta.json atomically (tmp file, fsync, rename). */
    fun update(draft: Draft) {
        val meta = with(draft) {
            Meta(status, createdMs, clock(), language, engine, text, error, app, tier, promptSha, uploadedMs = uploadedMs)
        }
        val tmp = File(draft.dir, "meta.json.tmp")
        FileOutputStream(tmp).use {
            it.write(json.encodeToString(Meta.serializer(), meta).toByteArray())
            it.fd.sync()
        }
        if (!tmp.renameTo(File(draft.dir, "meta.json"))) throw IOException("cannot write ${draft.dir}/meta.json")
    }

    /** Deletes the draft (audio, meta, segments) at once: delivered into an incognito field. */
    fun delete(draft: Draft) {
        draft.dir.deleteRecursively()
    }

    /** Appends [segment] to the draft's segments.jsonl and fsyncs it. */
    fun addSegment(draft: Draft, segment: SegmentText) {
        FileOutputStream(File(draft.dir, SEGMENTS), true).use {
            it.write((json.encodeToString(SegmentText.serializer(), segment) + "\n").toByteArray())
            it.fd.sync()
        }
    }

    /** The draft's segment texts in order; a line cut short by a kill is skipped. */
    fun segments(draft: Draft): List<SegmentText> {
        val file = File(draft.dir, SEGMENTS)
        if (!file.isFile) return emptyList()
        return file.readLines().mapNotNull {
            try {
                json.decodeFromString(SegmentText.serializer(), it)
            } catch (e: Exception) {
                null
            }
        }.sortedBy { it.start }
    }

    /**
     * The draft, or null if it has neither readable meta nor audio. A pending
     * draft's WAV is repaired (app killed while recording): never load the
     * draft being recorded, its writer patches the header on close.
     */
    fun load(id: String): Draft? {
        val dir = File(root, id)
        val meta = readMeta(dir) ?: lostMeta(dir) ?: return null
        val draft = with(meta) {
            Draft(
                id, dir, status, createdMs, language, engine, text, error, app,
                if (tier == TIER_WORK) TIER_WORK else TIER_PERSONAL, promptSha, uploadedMs,
            )
        }
        if (draft.status == DraftStatus.PENDING && draft.audio.exists()) {
            try {
                WavFiles.repair(draft.audio)
            } catch (e: IOException) {
                // Keep the draft listed; its text (if any) is still usable.
            }
        }
        return draft
    }

    /** Pending drafts, oldest first; those [isActive] (being recorded) are skipped before loading. */
    fun pending(isActive: (String) -> Boolean = { false }): List<Draft> =
        ids().filterNot(isActive).mapNotNull(::load).filter { it.status == DraftStatus.PENDING }.sortedBy { it.createdMs }

    /**
     * Deletes delivered/cancelled drafts finished more than [keepDays] ago. With a
     * training lab ([unsentDays] non-null), a delivered draft it has not received
     * yet is kept until [unsentDays]: the hub being off must not lose it.
     */
    fun prune(keepDays: Int, unsentDays: Int? = null) {
        val day = 24L * 3_600_000
        for (id in ids()) {
            val dir = File(root, id)
            val meta = readMeta(dir) ?: continue
            val unsent = unsentDays != null && meta.status == DraftStatus.DELIVERED && meta.uploadedMs == null
            val days = if (unsent) maxOf(keepDays, unsentDays!!) else keepDays
            if (meta.status != DraftStatus.PENDING && meta.updatedMs < clock() - days * day) dir.deleteRecursively()
        }
    }

    /**
     * Delivered drafts the training lab has not received yet, oldest first;
     * only those last changed at or before [settledBefore] (Undo may still
     * cancel a fresher one).
     */
    fun toUpload(settledBefore: Long = Long.MAX_VALUE): List<Draft> = ids().filter { id ->
        readMeta(File(root, id))?.let { it.status == DraftStatus.DELIVERED && it.uploadedMs == null && it.updatedMs <= settledBefore } == true
    }.mapNotNull(::load).sortedBy { it.createdMs }

    /** What goes to the lab: meta.json, segments.jsonl (if any), audio.wav. */
    fun files(draft: Draft): List<File> =
        listOf(File(draft.dir, "meta.json"), File(draft.dir, SEGMENTS), draft.audio).filter { it.isFile }

    private fun ids(): List<String> = root.listFiles { f -> f.isDirectory }?.map { it.name }.orEmpty()

    // Killed before meta.json reached the disk: keep the audio as a pending
    // draft, created when its id says (or the audio's mtime); language unknown.
    private fun lostMeta(dir: File): Meta? {
        val audio = File(dir, "audio.wav")
        if (!audio.isFile) return null
        val created = try {
            Instant.from(idTime.parse(dir.name.substringBefore('-'))).toEpochMilli()
        } catch (e: Exception) {
            audio.lastModified()
        }
        return Meta(DraftStatus.PENDING, created, created, UNKNOWN_LANGUAGE)
    }

    private fun readMeta(dir: File): Meta? = try {
        json.decodeFromString(Meta.serializer(), File(dir, "meta.json").readText())
    } catch (e: Exception) {
        null
    }

    companion object {
        private const val SEGMENTS = "segments.jsonl"

        /** Language of a draft whose meta was lost: Whisper detects it. */
        const val UNKNOWN_LANGUAGE = "auto"
    }
}
