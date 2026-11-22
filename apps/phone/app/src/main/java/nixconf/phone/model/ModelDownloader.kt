package nixconf.phone.model

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import nixconf.phone.profile.Archive
import nixconf.phone.profile.LocalModel
import nixconf.phone.profile.ModelFile
import okhttp3.OkHttpClient
import okhttp3.Request
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream

class NotOnWifi : IOException("not on an unmetered network; download now to use mobile data")

class UnsafeName(name: String) : IOException("unsafe file name in profile: \"$name\"")

class HashMismatch(what: String) : IOException("$what: sha256 mismatch")

// The on-phone model, in <dir>/<model name>/. A file is fetched to
// `<name>.part` (resumed with Range on the next attempt), checked against the
// profile's sha256, then renamed; `<name>.sha256` records "<sha256> <length>"
// of the verified file, so isReady() never hashes 600 MB and a `.part` file is
// never loaded. When the per-file URLs (butternut) fail, the upstream release
// archive is fetched and the files extracted from it.
class ModelDownloader(
    private val http: OkHttpClient,
    private val dir: File,
    private val isUnmetered: () -> Boolean,
) {
    fun modelDir(model: LocalModel) = File(dir, model.name)

    fun isReady(model: LocalModel): Boolean =
        unsafeName(model) == null && model.files.all { verified(modelDir(model), it) }

    /**
     * The model directory once every file is verified. Fails with [UnsafeName]
     * (before touching the disk) when the profile names a path, and with
     * [NotOnWifi] on a metered network unless [force].
     */
    suspend fun download(model: LocalModel, force: Boolean = false, progress: (Long, Long) -> Unit): Result<File> {
        unsafeName(model)?.let { return Result.failure(UnsafeName(it)) }
        if (isReady(model)) return Result.success(modelDir(model))
        if (!force && !isUnmetered()) return Result.failure(NotOnWifi())
        return try {
            withContext(Dispatchers.IO) { fetchAll(model, progress) }
            Result.success(modelDir(model))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun fetchAll(model: LocalModel, progress: (Long, Long) -> Unit) {
        val out = modelDir(model)
        if (!out.mkdirs() && !out.isDirectory) throw IOException("cannot create $out")
        val total = model.files.sumOf { it.size }
        var done = 0L
        try {
            for (f in model.files) {
                if (!adopt(out, f)) {
                    fetch(f.url, File(out, "${f.name}.part")) { n, _ -> progress(done + n, total) }
                    finish(out, f)
                }
                done += f.size
                progress(done, total)
            }
        } catch (e: IOException) {
            if (e is HashMismatch) throw e
            val archive = model.archive ?: throw e
            try {
                fromArchive(out, model, archive, progress)
            } catch (e2: IOException) {
                e2.addSuppressed(e)
                throw e2
            }
        }
    }

    // Already verified, or a whole file left without its record (killed
    // between rename and record): hash it rather than fetch it again.
    private fun adopt(out: File, f: ModelFile): Boolean {
        if (verified(out, f)) return true
        val file = File(out, f.name)
        if (!file.isFile) return false
        if (sha256(file) == f.sha256.lowercase()) {
            record(out, f, file)
            return true
        }
        file.delete()
        return false
    }

    /** Appends to [part] from its current length (`Range`), or starts over when the server ignores the range. */
    private suspend fun fetch(url: String, part: File, onBytes: (Long, Long) -> Unit) {
        val have = if (part.isFile) part.length() else 0L
        val request = Request.Builder().url(url).apply { if (have > 0) header("Range", "bytes=$have-") }.build()
        http.newCall(request).execute().use { response ->
            val append = when {
                // Nothing left to send: the part is whole; the hash check decides.
                have > 0 && response.code == 416 -> return
                have > 0 && response.code == 206 &&
                    response.header("Content-Range")?.startsWith("bytes $have-") == true -> true
                response.code == 200 -> false
                else -> throw IOException("$url: HTTP ${response.code}")
            }
            val body = response.body ?: throw IOException("$url: empty answer")
            var n = if (append) have else 0L
            val total = body.contentLength().takeIf { it >= 0 }?.plus(n) ?: -1L
            FileOutputStream(part, append).use { file ->
                body.byteStream().use { input ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buf)
                        if (read < 0) break
                        file.write(buf, 0, read)
                        n += read
                        onBytes(n, total)
                    }
                }
                file.fd.sync()
            }
        }
    }

    private fun finish(out: File, f: ModelFile) {
        val part = File(out, "${f.name}.part")
        if (sha256(part) != f.sha256.lowercase()) {
            part.delete()
            throw HashMismatch(f.name)
        }
        val file = File(out, f.name)
        file.delete()
        if (!part.renameTo(file)) throw IOException("cannot rename $part")
        record(out, f, file)
    }

    private suspend fun fromArchive(out: File, model: LocalModel, archive: Archive, progress: (Long, Long) -> Unit) {
        val whole = File(out, "archive.tar.bz2")
        if (!whole.isFile || sha256(whole) != archive.sha256.lowercase()) {
            whole.delete()
            val part = File(out, "archive.tar.bz2.part")
            fetch(archive.url, part, progress)
            if (sha256(part) != archive.sha256.lowercase()) {
                part.delete()
                throw HashMismatch(archive.url)
            }
            if (!part.renameTo(whole)) throw IOException("cannot rename $part")
        }
        // The release tarball has a top directory and test WAVs: take the files by name.
        val wanted = model.files.filterNot { verified(out, it) }.associateBy { it.name }
        TarArchiveInputStream(BZip2CompressorInputStream(whole.inputStream().buffered())).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                val f = wanted[entry.name.substringAfterLast('/')]
                if (!entry.isFile || f == null) continue
                coroutineContext.ensureActive()
                FileOutputStream(File(out, "${f.name}.part")).use {
                    tar.copyTo(it)
                    it.fd.sync()
                }
                finish(out, f)
            }
        }
        val missing = model.files.filterNot { verified(out, it) }
        if (missing.isNotEmpty()) throw IOException("archive lacks ${missing.joinToString { it.name }}")
        whole.delete()
    }

    // Names come from the profile and become paths under [dir]: plain file
    // names only, no separators, no "." / "..".
    private fun unsafeName(model: LocalModel): String? =
        (listOf(model.name) + model.files.map { it.name }).firstOrNull {
            !SAFE_NAME.matches(it) || it == "." || ".." in it
        }

    private fun verified(out: File, f: ModelFile): Boolean = try {
        val file = File(out, f.name)
        val rec = File(out, "${f.name}.sha256")
        file.isFile && rec.isFile && rec.readText().trim() == "${f.sha256.lowercase()} ${file.length()}"
    } catch (e: IOException) {
        false
    }

    private fun record(out: File, f: ModelFile, file: File) =
        File(out, "${f.name}.sha256").writeText("${f.sha256.lowercase()} ${file.length()}\n")

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buf)
                if (read < 0) break
                digest.update(buf, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private companion object {
        val SAFE_NAME = Regex("[A-Za-z0-9._-]+")
    }
}
