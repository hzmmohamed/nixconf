package nixconf.phone.engine

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive

// Who transcribes a session, decided once at mic press.
sealed interface Engine {
    data class Remote(val url: String) : Engine
    data object Local : Engine
    data object Unavailable : Engine
}

/**
 * The keyboard's Auto / Phone toggle. [AUTO]: a server that is plugged in,
 * else the phone. [PHONE]: the phone whenever it can (English, model ready),
 * without probing a server; a server only for what the phone cannot do.
 */
enum class Where {
    AUTO,
    PHONE,
    ;

    fun next(): Where = entries[(ordinal + 1) % entries.size]

    companion object {
        fun of(name: String?): Where = entries.firstOrNull { it.name == name } ?: AUTO
    }
}

// What the check of one server found.
private enum class Check { UP, ON_BATTERY, DOWN }

/**
 * Checks every server in parallel; the first in list order that answered wins
 * (as on the desktop), so a nearer server listed first is preferred even when a
 * later one answers sooner. A server [onBattery] says runs on battery is
 * passed over (and not probed: a probe loads its model) for the next one, or
 * for the on-phone model if it is ready and speaks [language]; it is used
 * only when nothing else can transcribe. [onBattery]: null when unknown (no
 * power status for that server, or it did not answer). None at all: the
 * on-phone model, else [Engine.Unavailable].
 */
suspend fun chooseEngine(
    servers: List<String>,
    language: String,
    localReady: Boolean,
    localLanguage: String,
    where: Where = Where.AUTO,
    onBattery: suspend (String) -> Boolean? = { null },
    probe: suspend (String) -> Boolean,
): Engine {
    val localOk = localReady && language == localLanguage
    if (where == Where.PHONE && localOk) return Engine.Local
    return coroutineScope {
        val checks = servers.map { url ->
            async {
                when {
                    safely(null) { onBattery(url) } == true -> Check.ON_BATTERY
                    safely(false) { probe(url) } -> Check.UP
                    else -> Check.DOWN
                }
            }
        }
        var winner = -1
        for (i in checks.indices) {
            if (checks[i].await() == Check.UP) {
                winner = i
                break
            }
        }
        checks.forEach { it.cancel() }
        when {
            winner >= 0 -> Engine.Remote(servers[winner])
            localOk -> Engine.Local
            // Every check finished (none won): the servers on battery, in order.
            else -> servers.filterIndexed { i, _ -> checks[i].await() == Check.ON_BATTERY }
                .firstOrNull { safely(false) { probe(it) } }
                ?.let { Engine.Remote(it) }
                ?: Engine.Unavailable
        }
    }
}

private suspend fun <T> CoroutineScope.safely(fallback: T, block: suspend () -> T): T = try {
    block()
} catch (e: Exception) {
    ensureActive()
    fallback
}
