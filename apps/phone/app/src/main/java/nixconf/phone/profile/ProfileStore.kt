package nixconf.phone.profile

import java.io.File
import java.io.IOException

// Last good profile, cached as `profile.json` in [dir]; its mtime (set from
// [clock]) is the time of the last successful fetch. Never throws: without a
// network the cached profile (or null, before the first fetch) is used.
class ProfileStore(
    private val dir: File,
    private val fetch: (String) -> String,
    private val clock: () -> Long,
) {
    private val file = File(dir, "profile.json")

    fun cached(): Profile? = try {
        if (file.exists()) parseProfile(file.readText()) else null
    } catch (e: Exception) {
        null
    }

    fun refreshIfStale(url: String, maxAgeMs: Long = 3_600_000): Profile? {
        val cached = cached()
        if (cached != null && clock() - file.lastModified() < maxAgeMs) return cached
        return try {
            val text = fetch(url)
            val profile = parseProfile(text)
            save(text)
            profile
        } catch (e: Exception) {
            cached
        }
    }

    private fun save(text: String) {
        dir.mkdirs()
        val tmp = File(dir, "profile.json.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) throw IOException("cannot replace $file")
        file.setLastModified(clock())
    }

    companion object {
        const val DEFAULT_URL = "http://butternut:8180/profile.json"
    }
}
