package nixconf.phone.ime

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
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
    val message: String?,
)

class PanelActions(
    val mic: () -> Unit,
    val cancel: () -> Unit,
    val language: () -> Unit,
    val switchKeyboard: () -> Unit,
    val insert: (Draft) -> Unit,
    val copy: (Draft) -> Unit,
    val retry: (Draft) -> Unit,
)

// Not a key grid: a big latch mic (tap start, tap stop), what is happening,
// and the drafts the last sessions left behind.
@Composable
fun Panel(model: PanelModel, actions: PanelActions) {
    var showPending by remember { mutableStateOf(false) }
    val state = model.state
    val active = state is SessionState.Recording || state is SessionState.Transcribing
    // Drafts a server heard nothing in stay listed in the app, not here.
    val offered = model.pending.filter { it.error != DictationSession.NOTHING_HEARD }

    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = actions.switchKeyboard) { Text("⌨ Keyboard") }
                if (model.languages.size > 1) {
                    TextButton(onClick = actions.language, enabled = !active) { Text(model.language.uppercase()) }
                }
                Spacer(Modifier.weight(1f))
                if (active) TextButton(onClick = actions.cancel) { Text("Cancel") }
            }

            Row(
                Modifier.fillMaxWidth().padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                MicButton(state, actions.mic)
                Spacer(Modifier.width(16.dp))
                Column(Modifier.weight(1f)) { Status(state, model.level) }
            }

            model.message?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
            if (model.noProfile) {
                Text(
                    "No profile yet: open Nixconf on the tailnet once",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (offered.isNotEmpty() && !active) {
                AssistChip(onClick = { showPending = !showPending }, label = { Text("${offered.size} pending") })
                if (showPending) PendingList(offered, actions)
            }
        }
    }
}

@Composable
private fun MicButton(state: SessionState, onClick: () -> Unit) {
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
        enabled = state !is SessionState.Transcribing,
        shape = CircleShape,
        colors = colors,
        modifier = Modifier.size(80.dp).semantics {
            contentDescription = if (recording) "Stop recording" else "Start recording"
        },
    ) {
        Text(if (recording) "■" else "●", fontSize = 28.sp)
    }
}

@Composable
private fun Status(state: SessionState, level: Float) {
    when (state) {
        SessionState.Idle -> Text("Tap to dictate")
        is SessionState.Recording -> {
            var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
            LaunchedEffect(state.startedMs) {
                while (true) {
                    now = System.currentTimeMillis()
                    delay(250)
                }
            }
            Text("${elapsed(now - state.startedMs)} · ${engineLabel(state.engine)}")
            LinearProgressIndicator(progress = { level }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        }
        is SessionState.Transcribing -> {
            Text("Transcribing… · ${engineLabel(state.engine)}")
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth().padding(top = 6.dp))
        }
        is SessionState.Done -> Text(state.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        is SessionState.Kept -> Text(keptText(state.reason))
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PendingList(drafts: List<Draft>, actions: PanelActions) {
    Box(Modifier.heightIn(max = 180.dp)) {
        LazyColumn {
            items(drafts, key = { it.id }) { draft ->
                val text = draft.text
                Column(
                    Modifier.fillMaxWidth()
                        .combinedClickable(
                            onClick = { if (text != null) actions.insert(draft) else actions.retry(draft) },
                            onLongClick = { if (text != null) actions.copy(draft) },
                        )
                        .padding(vertical = 8.dp),
                ) {
                    Text(
                        text ?: "No text yet: tap to transcribe",
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        color = if (text != null) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                }
                HorizontalDivider()
            }
        }
    }
}
