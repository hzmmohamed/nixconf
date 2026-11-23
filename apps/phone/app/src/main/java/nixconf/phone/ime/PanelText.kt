package nixconf.phone.ime

import java.net.URI
import nixconf.phone.engine.Engine
import nixconf.phone.session.DictationSession
import nixconf.phone.session.SessionState

// The words on the keyboard panel and the drafts list, kept out of the
// Compose code so they can be tested on the JVM.

/** Who transcribes: the server's host label ("butternut"), "on phone" or "no server"; null while probing. */
fun engineLabel(engine: Engine?): String = when (engine) {
    null -> "checking…"
    is Engine.Remote -> hostOf(engine.url)
    Engine.Local -> "on phone"
    Engine.Unavailable -> "no server"
}

/** A draft's engine as stored ([nixconf.phone.drafts.Draft.engine]): server URL or "local". */
fun draftEngineLabel(engine: String?): String? = when (engine) {
    null -> null
    DictationSession.LOCAL_ENGINE -> "on phone"
    else -> hostOf(engine)
}

/** The host's first label (MagicDNS "butternut.<tailnet>.ts.net" → "butternut"); an IP as is. */
fun hostOf(url: String): String = try {
    val host = URI(url).host
    when {
        host == null -> url
        host.all { it.isDigit() || it == '.' } || host.startsWith("[") -> host
        else -> host.substringBefore('.')
    }
} catch (e: Exception) {
    url
}

/** "0:12 · butternut", plus " · transcribing…" while a segment is (recording goes on). */
fun recordingText(elapsedMs: Long, state: SessionState.Recording): String =
    "${elapsed(elapsedMs)} · ${engineLabel(state.engine)}" + if (state.transcribing) " · transcribing…" else ""

/** m:ss */
fun elapsed(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}

/** Why the last recording is a draft instead of typed text. */
fun keptText(reason: String): String = when (reason) {
    DictationSession.FIELD_CHANGED -> "Field changed: kept as draft"
    DictationSession.NO_SERVER -> "No server: kept as draft"
    DictationSession.NOTHING_HEARD -> "Nothing heard"
    DictationSession.LOCAL_FAILED -> "On-phone transcription failed: kept as draft"
    else -> "Kept as draft: $reason"
}

/** The language after [current] in [languages], wrapping around. */
fun nextLanguage(languages: List<String>, current: String): String {
    if (languages.isEmpty()) return current
    val i = languages.indexOf(current)
    return languages[(i + 1) % languages.size]
}
