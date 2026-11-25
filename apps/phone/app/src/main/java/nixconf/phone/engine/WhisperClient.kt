package nixconf.phone.engine

import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import nixconf.phone.drafts.SegmentConf
import nixconf.phone.drafts.WordConf
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.Response

/** A server's answer: the raw text and, from verbose_json, how sure Whisper was. */
data class Transcript(val text: String, val conf: SegmentConf? = null)

// What the dictation session needs from a server (a fake in its tests).
fun interface RemoteTranscriber {
    suspend fun transcribe(url: String, wav: File, language: String, prompt: String): Transcript
}

/** Which Whisper prompt a draft used: the first 12 hex of its SHA-256 (as dictate-stream's prompt_sha). */
fun promptSha(prompt: String): String =
    MessageDigest.getInstance("SHA-256").digest(prompt.toByteArray()).joinToString("") { "%02x".format(it) }.take(12)

/**
 * whisper-server's answer: the text, plus (verbose_json) the worst segment's
 * avg_logprob and no_speech_prob, every word with its probability and the
 * detected language. Null without `text`; conf is null without segments.
 */
fun parseInference(body: String): Transcript? {
    val o = try {
        Json.parseToJsonElement(body).jsonObject
    } catch (e: IllegalArgumentException) {
        return null
    }
    val text = o["text"]?.jsonPrimitive?.contentOrNull ?: return null
    val segments = try {
        o["segments"]?.jsonArray?.map { it.jsonObject }.orEmpty()
    } catch (e: IllegalArgumentException) {
        emptyList()
    }
    if (segments.isEmpty()) return Transcript(text)
    fun JsonObject.num(key: String) = this[key]?.jsonPrimitive?.doubleOrNull ?: 0.0
    // A malformed score must never cost the text.
    val words = try {
        segments.flatMap { seg ->
            seg["words"]?.jsonArray.orEmpty().map { it.jsonObject }.map {
                WordConf(it["word"]?.jsonPrimitive?.contentOrNull.orEmpty(), it.num("probability"), it.num("start"), it.num("end"))
            }
        }
    } catch (e: IllegalArgumentException) {
        return Transcript(text)
    }
    return Transcript(
        text,
        SegmentConf(
            avgLogprob = segments.minOf { it.num("avg_logprob") },
            noSpeechProb = segments.maxOf { it.num("no_speech_prob") },
            words = words,
            lang = o["detected_language"]?.jsonPrimitive?.contentOrNull,
            langP = o["detected_language_probability"]?.jsonPrimitive?.doubleOrNull,
        ),
    )
}

// whisper.cpp's server as run by dictation-server: `GET /` is the readiness
// probe (and starts the socket-activated server), `POST /inference` takes a
// 16 kHz mono WAV and answers {"text": …, "segments": […]} (verbose_json).
class WhisperClient(private val http: OkHttpClient) : RemoteTranscriber {
    /**
     * As the desktop `dictate`: a host that is not there fails at connect
     * ([connectMs]); one that accepts gets [timeoutMs] to answer, as a cold
     * server answers only once the model is loaded and warm (1-3 s on
     * butternut). The session records meanwhile, so the wait costs nothing.
     */
    suspend fun probe(url: String, connectMs: Long = 1500, timeoutMs: Long = 20_000): Boolean {
        val client = http.newBuilder()
            .connectTimeout(connectMs, TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .build()
        val request = Request.Builder().url(endpoint(url, "")).build()
        return try {
            client.newCall(request).await { it.isSuccessful }
        } catch (e: IOException) {
            false
        }
    }

    /** The raw transcript; throws [IOException] on a non-2xx answer or one without `text`. */
    override suspend fun transcribe(url: String, wav: File, language: String, prompt: String): Transcript {
        val client = http.newBuilder()
            .readTimeout(TIMEOUT_S, TimeUnit.SECONDS)
            .callTimeout(TIMEOUT_S, TimeUnit.SECONDS)
            .build()
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", wav.name, wav.asRequestBody("audio/wav".toMediaType()))
            .addFormDataPart("language", language)
            .addFormDataPart("response_format", "verbose_json")
            .addFormDataPart("prompt", prompt)
            .addFormDataPart("temperature", "0.0")
            .addFormDataPart("temperature_inc", "0.2")
            .build()
        val request = Request.Builder().url(endpoint(url, "inference")).post(body).build()
        val answer = client.newCall(request).await { response ->
            if (!response.isSuccessful) throw IOException("$url: HTTP ${response.code}")
            response.body?.string().orEmpty()
        }
        return parseInference(answer) ?: throw IOException("$url: answer has no text")
    }

    private fun endpoint(url: String, path: String) = url.trimEnd('/') + "/" + path

    private companion object {
        const val TIMEOUT_S = 120L
    }
}

// Runs the call on OkHttp's threads and [read]s the response there (no network
// I/O on the caller's thread, which may be the main one); cancelling the
// coroutine cancels the call.
internal suspend fun <T> Call.await(read: (Response) -> T): T = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) = cont.resumeWithException(e)

        override fun onResponse(call: Call, response: Response) =
            cont.resumeWith(runCatching { response.use(read) })
    })
}
