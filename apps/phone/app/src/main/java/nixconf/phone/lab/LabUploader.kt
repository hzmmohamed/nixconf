package nixconf.phone.lab

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
    /** Uploads every delivered, not yet uploaded draft, oldest first; how many made it. */
    suspend fun uploadAll(lab: String): Int = withContext(Dispatchers.IO) {
        val client = http.newBuilder().writeTimeout(60, TimeUnit.SECONDS).callTimeout(120, TimeUnit.SECONDS).build()
        var sent = 0
        for (draft in drafts.toUpload()) {
            val base = "${lab.trimEnd('/')}/inbox/phone/${draft.id}"
            try {
                for (file in drafts.files(draft)) {
                    call(client, Request.Builder().url("$base/${file.name}").put(file.asRequestBody(OCTETS)).build())
                }
                call(client, Request.Builder().url("$base/done").post(ByteArray(0).toRequestBody(OCTETS)).build())
            } catch (e: IOException) {
                break
            } catch (e: IllegalArgumentException) {
                break // a malformed lab URL
            }
            drafts.update(draft.copy(uploadedMs = clock()))
            sent++
        }
        sent
    }

    private fun call(client: OkHttpClient, request: Request) {
        client.newCall(request).execute().use {
            if (!it.isSuccessful) throw IOException("${request.url.encodedPath}: HTTP ${it.code}")
        }
    }

    private companion object {
        val OCTETS = "application/octet-stream".toMediaType()
    }
}
