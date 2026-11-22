package nixconf.phone.engine

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
 * Probes every server in parallel; the first in list order that answered wins
 * (as on the desktop), so a nearer server listed first is preferred even when a
 * later one answers sooner. None: the on-phone model if it is ready and speaks
 * [language], else [Engine.Unavailable].
 */
suspend fun chooseEngine(
    servers: List<String>,
    language: String,
    localReady: Boolean,
    localLanguage: String,
    probe: suspend (String) -> Boolean,
): Engine = coroutineScope {
    val answers = servers.map { url ->
        async {
            try {
                probe(url)
            } catch (e: Exception) {
                ensureActive()
                false
            }
        }
    }
    val winner = answers.indexOfFirst { it.await() }
    answers.forEach { it.cancel() }
    when {
        winner >= 0 -> Engine.Remote(servers[winner])
        localReady && language == localLanguage -> Engine.Local
        else -> Engine.Unavailable
    }
}
