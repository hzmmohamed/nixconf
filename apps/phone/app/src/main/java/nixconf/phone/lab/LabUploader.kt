package nixconf.phone.lab

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.DraftStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody

// Sends delivered drafts to the dictation training lab's inbox on butternut
// (dictation-lab feature, profile `lab`): each file by PUT, then POST done,
// which normalizes it there; the draft is then marked uploaded (and pruned
// as usual). The first failure stops the run: the hub is off or away, the
// rest wait for the next chance. Only the user's own tailnet devices get in.
class LabUploader(private val http: OkHttpClient, private val drafts: DraftStore, private val clock: () -> Long) {
    /**
     * Uploads every delivered draft the lab has not received, oldest first,
     * once it has settled for [SETTLE_MS] (Undo may still cancel a fresh one);
     * how many made it. A draft the hub rejects (4xx) is skipped; an error
     * that means the hub is away (no connection, 5xx) ends the run.
     */
    suspend fun uploadAll(lab: String): Int = withContext(Dispatchers.IO) {
        val client = http.newBuilder().writeTimeout(60, TimeUnit.SECONDS).callTimeout(120, TimeUnit.SECONDS).build()
        var sent = 0
        for (draft in drafts.toUpload(settledBefore = clock() - SETTLE_MS)) {
            val base = "${lab.trimEnd('/')}/inbox/phone/${draft.id}"
            try {
                for (file in drafts.files(draft)) {
                    call(client, Request.Builder().url("$base/${file.name}").put(file.asRequestBody(OCTETS)).build())
                }
                call(client, Request.Builder().url("$base/done").post(ByteArray(0).toRequestBody(OCTETS)).build())
                // As on disk now: an Undo meanwhile made it CANCELLED, which stays.
                val now = drafts.load(draft.id)
                if (now?.status == DraftStatus.DELIVERED) {
                    drafts.update(now.copy(uploadedMs = clock()))
                    sent++
                }
            } catch (e: Rejected) {
                continue
            } catch (e: IOException) {
                break
            } catch (e: IllegalArgumentException) {
                break // a malformed lab URL
            }
        }
        sent
    }

    private class Rejected(message: String) : IOException(message)

    private fun call(client: OkHttpClient, request: Request) {
        client.newCall(request).execute().use {
            if (it.code in 400..499) throw Rejected("${request.url.encodedPath}: HTTP ${it.code}")
            if (!it.isSuccessful) throw IOException("${request.url.encodedPath}: HTTP ${it.code}")
        }
    }

    companion object {
        /** How long a delivered draft waits before it goes up (the Undo window, in practice). */
        const val SETTLE_MS = 10 * 60_000L

        private val OCTETS = "application/octet-stream".toMediaType()
    }
}
