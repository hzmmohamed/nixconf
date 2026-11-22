package nixconf.phone.ui

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import nixconf.phone.AppServices
import nixconf.phone.ModelStatus
import nixconf.phone.drafts.DraftStatus
import nixconf.phone.drafts.Draft
import nixconf.phone.ime.draftEngineLabel
import nixconf.phone.profile.Profile

/**
 * The app screen: microphone permission (the keyboard cannot ask), enabling
 * the keyboard, the profile URL and a server test, the on-phone model, and
 * the pending drafts (retry, copy, share the audio, discard).
 */
class MainActivity : ComponentActivity() {
    private lateinit var app: AppServices
    private var micGranted by mutableStateOf(false)
    private val askMic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { micGranted = it }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app = AppServices.of(this)
        setContent { NixconfTheme { Screen() } }
    }

    override fun onResume() {
        super.onResume()
        micGranted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        app.onOpen()
    }

    @Composable
    private fun Screen() {
        val profile by app.profile.collectAsState()
        val model by app.modelStatus.collectAsState()
        val pending by app.pending.collectAsState()
        Surface(Modifier.fillMaxSize()) {
            LazyColumn(
                Modifier.fillMaxSize().padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item { Text("Nixconf", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 24.dp)) }
                item { KeyboardSection() }
                item { ProfileSection(profile) }
                item { ModelSection(model) }
                drafts(pending)
                item { Text("", Modifier.padding(bottom = 24.dp)) }
            }
        }
    }

    @Composable
    private fun Section(title: String, content: @Composable () -> Unit) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium)
                content()
            }
        }
    }

    @Composable
    private fun KeyboardSection() = Section("Keyboard") {
        if (!micGranted) {
            Text("The keyboard needs the microphone.")
            Button(onClick = { askMic.launch(Manifest.permission.RECORD_AUDIO) }) { Text("Allow microphone") }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)) }) {
                Text("Enable keyboard")
            }
            OutlinedButton(onClick = { getSystemService(InputMethodManager::class.java).showInputMethodPicker() }) {
                Text("Switch keyboard")
            }
        }
    }

    @Composable
    private fun ProfileSection(profile: Profile?) = Section("Profile") {
        val scope = rememberCoroutineScope()
        var url by remember { mutableStateOf(app.profileUrl) }
        var results by remember { mutableStateOf<List<String>?>(null) }
        OutlinedTextField(
            value = url,
            onValueChange = { url = it },
            label = { Text("Profile URL") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        val fetched = app.profileFetchedMs()
        Text(
            if (profile == null) {
                "No profile yet"
            } else {
                "Fetched ${DateFormat.getDateTimeInstance().format(Date(fetched))} · " +
                    "${profile.servers.size} server(s) · ${profile.languages.joinToString()}"
            },
            style = MaterialTheme.typography.bodySmall,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = {
                app.profileUrl = url
                app.onOpen(force = true)
            }) { Text("Save & fetch") }
            // Probe the profile and every server it lists; show what answers.
            OutlinedButton(onClick = {
                results = listOf("Testing…")
                scope.launch {
                    val before = app.profileFetchedMs()
                    app.profileUrl = url
                    app.onOpen(force = true).join()
                    val p = app.profile.value
                    val lines = p?.servers.orEmpty().map { s ->
                        async { "$s: " + if (app.whisper.probe(s, 3000)) "answers" else "no answer" }
                    }.awaitAll()
                    val head = if (app.profileFetchedMs() > before) "Profile: fetched" else "Profile: not reachable (using cached)"
                    results = listOf(head) + lines
                }
            }) { Text("Test") }
        }
        results?.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
    }

    @Composable
    private fun ModelSection(status: ModelStatus) = Section("On-phone model") {
        when (status) {
            ModelStatus.NoProfile -> Text("Comes with the profile")
            ModelStatus.Ready -> Text("Parakeet ready (English, offline)")
            is ModelStatus.Missing -> {
                Text("Not downloaded" + (status.error?.let { ": $it" } ?: ""))
                Text("Downloads by itself on Wi-Fi; about 650 MB.", style = MaterialTheme.typography.bodySmall)
                Button(onClick = { app.downloadModel(force = true) }) { Text("Download now") }
            }
            is ModelStatus.Downloading -> {
                val mb = { b: Long -> b / 1_000_000 }
                Text("Downloading ${mb(status.done)} / ${mb(status.total)} MB")
                val total = status.total.coerceAtLeast(1)
                LinearProgressIndicator(progress = { status.done.toFloat() / total }, modifier = Modifier.fillMaxWidth())
            }
        }
    }

    private fun LazyListScope.drafts(pending: List<Draft>) {
        item { Text("Pending drafts (${pending.size})", style = MaterialTheme.typography.titleMedium) }
        if (pending.isEmpty()) item { Text("None: every recording reached a field.") }
        items(pending, key = { it.id }) { DraftCard(it) }
    }

    @Composable
    private fun DraftCard(draft: Draft) {
        val scope = rememberCoroutineScope()
        var busy by remember { mutableStateOf(false) }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val meta = listOfNotNull(
                    DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(draft.createdMs)),
                    draft.language,
                    draftEngineLabel(draft.engine),
                )
                Text(meta.joinToString(" · "), style = MaterialTheme.typography.bodySmall)
                Text(draft.text ?: "No text yet")
                draft.error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
                Row {
                    TextButton(enabled = !busy, onClick = {
                        busy = true
                        scope.launch {
                            val updated = app.session.retry(draft)
                            updated.text?.let(::copy)
                            busy = false
                            app.reloadPending()
                        }
                    }) { Text(if (busy) "Transcribing…" else "Retry") }
                    TextButton(enabled = draft.text != null, onClick = { draft.text?.let(::copy) }) { Text("Copy") }
                    TextButton(enabled = draft.audio.exists(), onClick = { share(draft) }) { Text("Share audio") }
                    TextButton(onClick = { discard(draft) }) { Text("Discard") }
                }
            }
        }
    }

    private fun copy(text: String) {
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("dictation", text))
    }

    private fun share(draft: Draft) {
        val uri = FileProvider.getUriForFile(this, "$packageName.files", draft.audio)
        val send = Intent(Intent.ACTION_SEND)
            .setType("audio/wav")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(send, "Share recording"))
    }

    // CANCELLED, not deleted: pruned with the others after keepDays.
    private fun discard(draft: Draft) {
        app.scope.launch {
            try {
                app.drafts.update(draft.copy(status = DraftStatus.CANCELLED))
            } catch (e: java.io.IOException) {
                // Stays pending; shown again.
            }
            app.reloadPending()
        }
    }
}
