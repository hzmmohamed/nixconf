package nixconf.phone.engine

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.Response

// whisper.cpp's server as run by dictation-server: `GET /` is the readiness
// probe (and starts the socket-activated server), `POST /inference` takes a
// 16 kHz mono WAV and answers {"text": …}.
class WhisperClient(private val http: OkHttpClient) {
    suspend fun probe(url: String, timeoutMs: Long = 1500): Boolean {
        val client = http.newBuilder().callTimeout(timeoutMs, TimeUnit.MILLISECONDS).build()
        val request = Request.Builder().url(endpoint(url, "")).build()
        return try {
            client.newCall(request).await { it.isSuccessful }
        } catch (e: IOException) {
            false
        }
    }

    /** The raw transcript; throws [IOException] on a non-2xx answer or one without `text`. */
    suspend fun transcribe(url: String, wav: File, language: String, prompt: String): String {
        val client = http.newBuilder()
            .readTimeout(TIMEOUT_S, TimeUnit.SECONDS)
            .callTimeout(TIMEOUT_S, TimeUnit.SECONDS)
            .build()
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", wav.name, wav.asRequestBody("audio/wav".toMediaType()))
            .addFormDataPart("language", language)
            .addFormDataPart("response_format", "json")
            .addFormDataPart("prompt", prompt)
            .addFormDataPart("temperature", "0.0")
            .addFormDataPart("temperature_inc", "0.2")
            .build()
        val request = Request.Builder().url(endpoint(url, "inference")).post(body).build()
        val answer = client.newCall(request).await { response ->
            if (!response.isSuccessful) throw IOException("$url: HTTP ${response.code}")
            response.body?.string().orEmpty()
        }
        return try {
            Json.parseToJsonElement(answer).jsonObject["text"]?.jsonPrimitive?.contentOrNull
        } catch (e: IllegalArgumentException) {
            null
        } ?: throw IOException("$url: answer has no text")
    }

    private fun endpoint(url: String, path: String) = url.trimEnd('/') + "/" + path

    private companion object {
        const val TIMEOUT_S = 120L
    }
}

// Runs the call on OkHttp's threads and [read]s the response there (no network
// I/O on the caller's thread, which may be the main one); cancelling the
// coroutine cancels the call.
private suspend fun <T> Call.await(read: (Response) -> T): T = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) = cont.resumeWithException(e)

        override fun onResponse(call: Call, response: Response) =
            cont.resumeWith(runCatching { response.use(read) })
    })
}
