package nixconf.phone.update

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import nixconf.phone.model.HashMismatch
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** app.json, as written by `phone-app publish` next to the profile. */
@Serializable
data class AppRelease(val versionCode: Int, val versionName: String, val url: String, val sha256: String)

// In-app update: the profile's appUrl points at app.json; a newer versionCode
// is offered, its APK fetched into [dir], checked against the sha256 and
// handed to [installer] (Android's package installer; the user confirms).
class Updater(
    private val http: OkHttpClient,
    private val dir: File,
    private val installer: (File) -> Unit,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /** The published release if it is newer than [currentVersionCode]; throws [IOException] when app.json is unreachable. */
    suspend fun check(appUrl: String, currentVersionCode: Int): AppRelease? = withContext(Dispatchers.IO) {
        val text = http.newCall(Request.Builder().url(appUrl).build()).execute().use {
            if (!it.isSuccessful) throw IOException("$appUrl: HTTP ${it.code}")
            it.body?.string() ?: throw IOException("$appUrl: empty answer")
        }
        val release = try {
            json.decodeFromString(AppRelease.serializer(), text)
        } catch (e: IllegalArgumentException) {
            throw IOException("$appUrl: not an app.json", e)
        }
        val url = appUrl.toHttpUrl().resolve(release.url) ?: throw IOException("$appUrl: bad url ${release.url}")
        release.copy(url = url.toString()).takeIf { it.versionCode > currentVersionCode }
    }

    /** The APK, verified; a mismatch deletes it and throws [HashMismatch]. */
    suspend fun downloadVerified(r: AppRelease): File = withContext(Dispatchers.IO) {
        if (!dir.mkdirs() && !dir.isDirectory) throw IOException("cannot create $dir")
        val file = File(dir, "nixconf-phone-${r.versionCode}.apk")
        val part = File(dir, "${file.name}.part")
        // Earlier updates (installed or not) are of no further use.
        dir.listFiles()?.forEach { it.delete() }
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            http.newCall(Request.Builder().url(r.url).build()).execute().use { response ->
                if (!response.isSuccessful) throw IOException("${r.url}: HTTP ${response.code}")
                val body = response.body ?: throw IOException("${r.url}: empty answer")
                FileOutputStream(part).use { out ->
                    body.byteStream().use { input ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            digest.update(buf, 0, n)
                        }
                    }
                }
            }
            val hex = digest.digest().joinToString("") { "%02x".format(it) }
            if (hex != r.sha256.lowercase()) throw HashMismatch(r.url)
            file.delete()
            if (!part.renameTo(file)) throw IOException("cannot rename $part")
            file
        } catch (e: Throwable) {
            part.delete()
            throw e
        }
    }

    fun install(file: File) = installer(file)
}
