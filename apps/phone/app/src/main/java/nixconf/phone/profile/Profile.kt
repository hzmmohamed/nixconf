package nixconf.phone.profile

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// The phone profile served by dictation-server (`phone.profile`, profile.json):
// which servers to try, languages, Whisper prompt, draft retention, the
// on-phone model to download, how a recording is cut and delivered
// (pauseMs, maxSegmentSec and mode, as on the laptops) and when one without
// speech stops itself (noSpeechSec; 0: never). Fields added later
// have defaults: a profile without them still parses, and an older app
// ignores them (ignoreUnknownKeys), so they need no version bump.
const val PROFILE_VERSION = 1

/** [Profile.mode]: each segment's text shows in the field as it lands (composing), committed at stop. */
const val MODE_STREAM = "stream"

/** [Profile.mode]: the whole text is typed at once, at stop. */
const val MODE_BATCH = "batch"

@Serializable
data class Profile(
    val version: Int,
    val servers: List<String> = emptyList(),
    val defaultLanguage: String = "en",
    val languages: List<String> = listOf(defaultLanguage),
    val prompt: String = "",
    val keepDays: Int = 7,
    val localModel: LocalModel? = null,
    val appUrl: String? = null,
    val pauseMs: Int = 550,
    val maxSegmentSec: Int = 25,
    val mode: String = MODE_BATCH,
    val noSpeechSec: Int = 10,
)

@Serializable
data class LocalModel(
    val name: String,
    val language: String,
    val files: List<ModelFile>,
    val archive: Archive? = null,
)

@Serializable
data class ModelFile(val name: String, val size: Long, val sha256: String, val url: String)

@Serializable
data class Archive(val url: String, val sha256: String)

class UnsupportedProfile(version: Int) :
    Exception("profile version $version is newer than this app supports ($PROFILE_VERSION)")

private val json = Json { ignoreUnknownKeys = true }

// The version is checked before decoding: a newer profile may have a shape
// this app cannot read at all.
fun parseProfile(text: String): Profile {
    val version = json.parseToJsonElement(text).jsonObject["version"]?.jsonPrimitive?.int
        ?: throw IllegalArgumentException("profile has no version")
    if (version > PROFILE_VERSION) throw UnsupportedProfile(version)
    return json.decodeFromString(Profile.serializer(), text)
}
