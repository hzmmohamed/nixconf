package nixconf.phone.ime

import java.net.URI
import nixconf.phone.engine.Engine
import nixconf.phone.engine.Where
import nixconf.phone.session.DictationSession
import nixconf.phone.session.Delivery
import nixconf.phone.session.SessionState

// The words on the keyboard panel and the drafts list, kept out of the
// Compose code so they can be tested on the JVM.

/** Who transcribes: the server's host label ("butternut"), "on phone" or "no server"; null while probing. */
fun engineLabel(engine: Engine?): String = when (engine) {
    null -> "finding server…"
    is Engine.Remote -> hostOf(engine.url)
    Engine.Local -> "on phone"
    Engine.Unavailable -> "no server · will save as draft"
}

/** The Auto / Phone toggle's text. */
fun whereLabel(where: Where): String = when (where) {
    Where.AUTO -> "Auto"
    Where.PHONE -> "Phone"
}

/** What the toggle means, for TalkBack. */
fun whereDescription(where: Where): String = when (where) {
    Where.AUTO -> "Transcribes on a plugged-in server, else on the phone"
    Where.PHONE -> "Transcribes on the phone"
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

/**
 * "0:12 · butternut", plus " · transcribing…" while a segment is (recording
 * goes on); "0:16 · nothing heard yet · stops in 4" while the no-speech
 * watchdog counts down.
 */
fun recordingText(elapsedMs: Long, state: SessionState.Recording): String = when (val left = state.stopsInSec) {
    null -> "${elapsed(elapsedMs)} · ${engineLabel(state.engine)}" + if (state.transcribing) " · transcribing…" else ""
    else -> "${elapsed(elapsedMs)} · nothing heard yet · stops in $left"
}

/** The Keep on toggle under the level meter, off and on. */
fun keepOnLabel(on: Boolean): String = if (on) "✓ Keeps recording in background" else "Keep recording in background"

/**
 * After stop: "Stopped · finding server…" until the probe answers, then
 * "Finishing 2 of 5 · butternut" while segments are queued, else "Transcribing… · butternut".
 */
fun finishingText(state: SessionState.Finishing): String = when {
    state.engine == null -> "Stopped · finding server…"
    state.total > state.done -> "Finishing ${state.done} of ${state.total} · ${engineLabel(state.engine)}"
    else -> "Transcribing… · ${engineLabel(state.engine)}"
}

/** The status line when nothing is running, by field. */
fun idleText(field: FieldKind, incognito: Boolean): String = when (field) {
    FieldKind.PASSWORD -> "Password field: switch keyboard to type"
    FieldKind.NUMERIC -> "Number field: dictated words may not fit"
    FieldKind.TEXT -> if (incognito) "Tap to dictate · incognito, no draft kept" else "Tap to dictate"
}

/** What TalkBack announces (liveRegion) for a state: short, no timer. */
fun announcement(state: SessionState, field: FieldKind, incognito: Boolean): String = when (state) {
    SessionState.Idle -> idleText(field, incognito)
    // Not the seconds: a polite announcement for each would pile up.
    is SessionState.Recording -> if (state.stopsInSec != null) "Nothing heard yet, stopping soon" else "Recording"
    is SessionState.Finishing -> when {
        state.engine == null -> "Stopped, finding server"
        state.total > state.done -> "Finishing ${state.done} of ${state.total}"
        else -> "Transcribing"
    }
    is SessionState.Done -> "Typed"
    is SessionState.Kept -> keptText(state.reason)
}

/** The mic button for TalkBack: what a tap does. */
fun micDescription(state: SessionState): String = when (state) {
    is SessionState.Recording -> "Stop recording"
    is SessionState.Finishing -> "Transcribing"
    else -> "Start dictation"
}

/** "3 drafts", "1 draft". */
fun draftsLabel(n: Int): String = if (n == 1) "1 draft" else "$n drafts"

/** A draft's age: "just now", "5 min ago", "3 h ago", "2 d ago". */
fun ageText(ms: Long): String {
    val min = ms / 60_000
    return when {
        min < 1 -> "just now"
        min < 60 -> "$min min ago"
        min < 24 * 60 -> "${min / 60} h ago"
        else -> "${min / (24 * 60)} d ago"
    }
}

/** Why start() failed, in plain words: [storage] (the draft) or the microphone. */
fun startError(storage: Boolean, message: String?): String = when {
    storage -> "Can't save the recording: storage full?"
    message != null && ("busy" in message || "unavailable" in message) -> "Microphone in use by another app"
    message != null && "already recording" in message -> "Microphone still in use by the last recording"
    else -> "Microphone failed" + (message?.let { ": $it" } ?: "")
}

/** Why a draft did not go in; null when it did. */
fun deliveryText(result: Delivery): String? = when (result) {
    Delivery.TYPED -> null
    Delivery.NO_TEXT -> "Not transcribed yet"
    Delivery.GONE -> "Already typed or discarded"
    Delivery.NO_FIELD -> "No field to type into"
    Delivery.BUSY -> "Finish the dictation first"
}

/** Undo found other text before the cursor (typed, moved, or another field): it leaves the field alone. */
const val UNDO_FAILED = "Can't undo: the text before the cursor changed"

/** m:ss */
fun elapsed(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%d:%02d".format(s / 60, s % 60)
}

/** Why the last recording is a draft instead of typed text. */
fun keptText(reason: String): String = when (reason) {
    DictationSession.FIELD_CHANGED -> "Saved as draft (field changed)"
    DictationSession.NO_SERVER -> "Saved as draft: no server. Transcribes when one is back"
    DictationSession.NOTHING_HEARD -> "Nothing heard: check the level bar"
    DictationSession.NO_SPEECH -> "Stopped: nothing heard. Mic muted or in use by another app? Tap to try again"
    DictationSession.LOCAL_FAILED -> "On-phone transcription failed: saved as draft"
    DictationSession.UNDONE -> "Removed from the field"
    else -> "Saved as draft: $reason"
}

/** The language after [current] in [languages], wrapping around. */
fun nextLanguage(languages: List<String>, current: String): String {
    if (languages.isEmpty()) return current
    val i = languages.indexOf(current)
    return languages[(i + 1) % languages.size]
}
