package nixconf.phone.ime

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import nixconf.phone.drafts.Draft
import nixconf.phone.session.DictationSession
import nixconf.phone.session.SessionState

/** What the panel shows; the keyboard service feeds it from AppServices. */
data class PanelModel(
    val state: SessionState,
    val level: Float,
    val noProfile: Boolean,
    val language: String,
    val languages: List<String>,
    val pending: List<Draft>,
    val notice: Notice?,
    val field: FieldKind = FieldKind.TEXT,
    val incognito: Boolean = false,
    val enterLabel: String = NEWLINE,
    // The keyboard switch waits for the text (tapped while finishing).
    val switchQueued: Boolean = false,
    // Drafts a tap is transcribing (to insert them).
    val retrying: Set<String> = emptySet(),
)

/** A one-line message under the status: info ("Copied") or an error. */
data class Notice(val text: String, val error: Boolean = false)

class PanelActions(
    val mic: () -> Unit,
    val cancel: () -> Unit,
    // Recording goes on with the keyboard closed (toggles).
    val keepOn: () -> Unit,
    val language: () -> Unit,
    val switchKeyboard: () -> Unit,
    val insert: (Draft) -> Unit,
    val copy: (Draft) -> Unit,
    val retry: (Draft) -> Unit,
    val delete: () -> Unit,
    val enter: () -> Unit,
)

// Close to a system keyboard's height, so neither the host app nor the mic
// moves between states (or when switching keyboards); at most about half a
// landscape screen.
private val PANEL_HEIGHT = 260.dp

// Not a key grid: a big latch mic (tap start, tap stop), what is happening,
// the drafts the last sessions left behind (in place of the mic, same
// height), and one row of keys for after the text: delete and enter.
@Composable
fun Panel(model: PanelModel, actions: PanelActions) {
    var showDrafts by remember { mutableStateOf(false) }
    val state = model.state
    val active = state is SessionState.Recording || state is SessionState.Finishing
    val password = model.field == FieldKind.PASSWORD && !active
    // Newest first: the one most likely wanted. Drafts a server heard nothing
    // in stay listed in the app, not here.
    val offered = model.pending.filter { it.error != DictationSession.NOTHING_HEARD }.sortedByDescending { it.createdMs }
    val draftsShown = showDrafts && !active && !password && offered.isNotEmpty()
    Haptics(state)

    val height = min(PANEL_HEIGHT, (LocalConfiguration.current.screenHeightDp * 0.55f).dp)
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().height(height).padding(horizontal = 12.dp, vertical = 4.dp)) {
            Row(Modifier.height(48.dp), verticalAlignment = Alignment.CenterVertically) {
                // Not while recording: the mic would keep going behind another keyboard
                // (unless kept on: that is what it is for).
                // While finishing: queued until the text is typed (switching now would end the input).
                TextButton(
                    onClick = actions.switchKeyboard,
                    enabled = state !is SessionState.Recording || state.background,
                    modifier = Modifier.semantics {
                        if (model.switchQueued) stateDescription = "Switches once the text is typed"
                    },
                ) {
                    Text(if (model.switchQueued) "⌨ After typing" else "⌨ Keyboard")
                }
                if (model.languages.size > 1) {
                    TextButton(onClick = actions.language, enabled = !active) { Text(model.language.uppercase()) }
                }
                Spacer(Modifier.weight(1f))
                when {
                    active -> TextButton(onClick = actions.cancel) { Text("Cancel") }
                    !password && offered.isNotEmpty() -> TextButton(onClick = { showDrafts = !showDrafts }) {
                        Text(if (draftsShown) "Back" else draftsLabel(offered.size))
                    }
                }
            }

            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (draftsShown) {
                    PendingList(offered, model.retrying, actions)
                } else {
                    Main(model, actions, password)
                }
            }

            KeyRow(enabled = !active, model.enterLabel, actions)
        }
    }
}

@Composable
private fun Main(model: PanelModel, actions: PanelActions, password: Boolean) {
    val state = model.state
    val elapsed = elapsedMs(state)
    // The row fills the slot: the mic stays put whatever the status shows.
    Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
        MicButton(state, enabled = !password, actions.mic)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
            Status(model, password, elapsed, actions)
            model.notice?.let {
                Text(
                    it.text,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (it.error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            val active = state is SessionState.Recording || state is SessionState.Finishing
            if (model.noProfile && !active) {
                Text(
                    "No profile: connect to the tailnet; retries when the keyboard opens",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun MicButton(state: SessionState, enabled: Boolean, onClick: () -> Unit) {
    val recording = state is SessionState.Recording
    val colors = if (recording) {
        ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.error,
            contentColor = MaterialTheme.colorScheme.onError,
        )
    } else {
        ButtonDefaults.buttonColors()
    }
    Button(
        onClick = onClick,
        enabled = enabled && state !is SessionState.Finishing,
        shape = CircleShape,
        colors = colors,
        modifier = Modifier.size(80.dp).semantics {
            contentDescription = micDescription(state)
            // Not the timer: TalkBack would read every tick of a focused button.
            if (recording) stateDescription = "Recording"
        },
    ) {
        if (state is SessionState.Finishing) {
            val progress = if (state.total > 0) state.done.toFloat() / state.total else null
            val spinner = Modifier.size(32.dp).clearAndSetSemantics {}
            if (progress != null) {
                CircularProgressIndicator(progress = { progress }, modifier = spinner, strokeWidth = 3.dp)
            } else {
                CircularProgressIndicator(modifier = spinner, strokeWidth = 3.dp)
            }
        } else {
            // The glyph is not read: the button's description says it.
            Text(if (recording) "■" else "●", fontSize = 28.sp, modifier = Modifier.clearAndSetSemantics {})
        }
    }
}

// The status slot: one line saying what is happening (announced politely,
// without the ticking timer), plus the level meter or a draft's actions.
@Composable
private fun Status(model: PanelModel, password: Boolean, elapsedMs: Long, actions: PanelActions) {
    // A password field shows only that it gets no dictation (no draft offered there either).
    val state = if (password) SessionState.Idle else model.state
    val line = when (state) {
        SessionState.Idle -> idleText(model.field, model.incognito)
        is SessionState.Recording -> recordingText(elapsedMs, state)
        is SessionState.Finishing -> finishingText(state)
        is SessionState.Done -> state.text
        is SessionState.Kept -> keptText(state.reason)
    }
    val announced = announcement(state, model.field, model.incognito)
    Text(
        line,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clearAndSetSemantics {
            liveRegion = LiveRegionMode.Polite
            contentDescription = if (state is SessionState.Done) "Typed: ${state.text}" else announced
        },
    )
    when (state) {
        is SessionState.Recording -> {
            LevelMeter(model.level)
            KeepOnToggle(state.background, actions.keepOn)
        }
        is SessionState.Kept -> KeptActions(state.draft, state.draft.id in model.retrying, actions)
        else -> Unit
    }
}

// The recording's level as a plain meter: decorative, not read out.
@Composable
private fun LevelMeter(level: Float) {
    Box(
        Modifier.padding(top = 8.dp).fillMaxWidth().height(4.dp)
            .clip(RoundedCornerShape(2.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(level.coerceIn(0f, 1f)).background(MaterialTheme.colorScheme.primary))
    }
}

// Keep on: the recording goes on when the keyboard closes (another app, the
// browser), with a notification to stop it.
@Composable
private fun KeepOnToggle(on: Boolean, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.semantics {
            stateDescription = if (on) "On: recording goes on when the keyboard closes" else "Off"
        },
    ) {
        Text(keepOnLabel(on))
    }
}

// A draft with its text: the text and Insert here / Copy; without: Retry
// (transcribes it and types it here).
@Composable
private fun KeptActions(draft: Draft, retrying: Boolean, actions: PanelActions) {
    val text = draft.text
    if (text != null) {
        Text(
            text,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 2.dp),
        )
        Row {
            TextButton(onClick = { actions.insert(draft) }) { Text("Insert here") }
            TextButton(onClick = { actions.copy(draft) }) { Text("Copy") }
        }
    } else {
        TextButton(onClick = { actions.retry(draft) }, enabled = !retrying) {
            Text(if (retrying) "Transcribing…" else "Retry")
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PendingList(drafts: List<Draft>, retrying: Set<String>, actions: PanelActions) {
    val now = remember { System.currentTimeMillis() }
    LazyColumn(Modifier.fillMaxSize()) {
        items(drafts, key = { it.id }) { draft ->
            val text = draft.text
            val busy = draft.id in retrying
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .combinedClickable(
                        enabled = !busy,
                        onClickLabel = if (text != null) "Insert here" else "Transcribe and insert",
                        onClick = { if (text != null) actions.insert(draft) else actions.retry(draft) },
                        onLongClick = { if (text != null) actions.copy(draft) },
                    )
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        text ?: if (busy) "Transcribing…" else "Not transcribed · tap to transcribe and insert",
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        color = if (text != null) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                    Text(
                        ageText(now - draft.createdMs),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                when {
                    busy -> CircularProgressIndicator(Modifier.padding(horizontal = 12.dp).size(20.dp), strokeWidth = 2.dp)
                    text != null -> TextButton(onClick = { actions.copy(draft) }) { Text("Copy") }
                }
            }
            HorizontalDivider()
        }
    }
}

// Delete (left) and the editor's enter key (right), off while a session
// runs: its text is still on the way.
@Composable
private fun KeyRow(enabled: Boolean, enterLabel: String, actions: PanelActions) {
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        DeleteKey(enabled, actions.delete)
        Spacer(Modifier.weight(1f))
        TextButton(
            onClick = actions.enter,
            enabled = enabled,
            modifier = Modifier.semantics { if (enterLabel == NEWLINE) contentDescription = "New line" },
        ) {
            Text(enterLabel, fontSize = if (enterLabel == NEWLINE) 20.sp else 14.sp)
        }
    }
}

// Deletes on press, then repeats while held (after 400 ms, every 50 ms).
@Composable
private fun DeleteKey(enabled: Boolean, onDelete: () -> Unit) {
    val delete by rememberUpdatedState(onDelete)
    var pressed by remember { mutableStateOf(false) }
    val colors = MaterialTheme.colorScheme
    Box(
        Modifier.size(width = 72.dp, height = 40.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (pressed) colors.surfaceContainerHighest else colors.surfaceContainerHigh)
            .semantics {
                role = Role.Button
                contentDescription = "Delete"
                if (!enabled) disabled()
                onClick {
                    delete()
                    true
                }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    awaitFirstDown().consume()
                    pressed = true
                    try {
                        delete()
                        var wait = 400L
                        while (withTimeoutOrNull(wait) { waitForUpOrCancellation() ?: Unit } == null) {
                            delete()
                            wait = 50L
                        }
                    } finally {
                        pressed = false
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "⌫",
            fontSize = 20.sp,
            color = if (enabled) colors.onSurface else colors.onSurface.copy(alpha = 0.38f),
            modifier = Modifier.clearAndSetSemantics {},
        )
    }
}

// Milliseconds since the recording started, ticking while it records.
@Composable
private fun elapsedMs(state: SessionState): Long {
    if (state !is SessionState.Recording) return 0
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.startedMs) {
        while (true) {
            now = System.currentTimeMillis()
            delay(250)
        }
    }
    return now - state.startedMs
}

// One haptic per transition that matters (Haptics.kt).
@Composable
private fun Haptics(state: SessionState) {
    val view = LocalView.current
    val last = remember { arrayOf(state) }
    LaunchedEffect(state) {
        hapticFor(last[0], state)?.let { view.performHapticFeedback(it.constant) }
        last[0] = state
    }
}
