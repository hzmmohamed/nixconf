package nixconf.phone.profile

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

// The phone profile served by dictation-server (`phone.profile`, profile.json):
// which servers to try, languages, Whisper prompt, draft retention and the
// on-phone model to download.
const val PROFILE_VERSION = 1

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
