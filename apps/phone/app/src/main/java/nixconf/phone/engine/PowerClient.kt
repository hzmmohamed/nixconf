package nixconf.phone.engine

import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request

// A server host's power status as dictation-server publishes it next to the
// phone profile (power.json: {"onBattery": true}), listed per server in the
// profile ([nixconf.phone.profile.Profile.power]).
class PowerClient(private val http: OkHttpClient) {
    /** Whether the host runs on battery; null if the status is missing or unreadable. Throws if the host does not answer. */
    suspend fun onBattery(url: String, connectMs: Long = 1500, timeoutMs: Long = 3000): Boolean? {
        val client = http.newBuilder()
            .connectTimeout(connectMs, TimeUnit.MILLISECONDS)
            .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
            .build()
        val answer = client.newCall(Request.Builder().url(url).build()).await { response ->
            if (response.isSuccessful) response.body?.string() else null
        } ?: return null
        return try {
            Json.parseToJsonElement(answer).jsonObject["onBattery"]?.jsonPrimitive?.booleanOrNull
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}
