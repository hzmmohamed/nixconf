package nixconf.phone.ime

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.ComposeView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.lifecycle.setViewTreeViewModelStoreOwner
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.launch
import nixconf.phone.AppServices
import nixconf.phone.drafts.Draft
import nixconf.phone.session.EditorTarget
import nixconf.phone.session.SessionState
import nixconf.phone.ui.MainActivity
import nixconf.phone.ui.NixconfTheme

/**
 * The dictation keyboard: a Compose panel (Panel.kt) over the shared
 * dictation session. It is the session's [EditorTarget]: the token names the
 * focused input session ([InputTokens]) and changes when the user moves on,
 * so text transcribed after a switch is kept as a draft instead of typed.
 * Hiding or destroying the keyboard stops a recording (never records unseen).
 * Compose needs lifecycle/view-model/saved-state owners on the window, which
 * an InputMethodService does not provide: the service is all three.
 */
class DictationIme :
    InputMethodService(),
    LifecycleOwner,
    ViewModelStoreOwner,
    SavedStateRegistryOwner,
    EditorTarget {

    private val registry = LifecycleRegistry(this)
    private val savedState = SavedStateRegistryController.create(this)
    override val lifecycle: Lifecycle get() = registry
    override val viewModelStore = ViewModelStore()
    override val savedStateRegistry: SavedStateRegistry get() = savedState.savedStateRegistry

    private lateinit var app: AppServices
    private var language by mutableStateOf<String?>(null)
    private var message by mutableStateOf<String?>(null)

    private val tokens = InputTokens()
    override val token: String? get() = tokens.token

    override fun onCreate() {
        super.onCreate()
        savedState.performRestore(null)
        registry.currentState = Lifecycle.State.CREATED
        app = AppServices.of(this)
    }

    override fun onCreateInputView(): View {
        window.window?.decorView?.let {
            it.setViewTreeLifecycleOwner(this)
            it.setViewTreeViewModelStoreOwner(this)
            it.setViewTreeSavedStateRegistryOwner(this)
        }
        return ComposeView(this).apply {
            setContent {
                val state by app.session.state.collectAsState()
                val level by app.recorder.level.collectAsState()
                val profile by app.profile.collectAsState()
                val pending by app.pending.collectAsState()
                val languages = profile?.languages.orEmpty()
                NixconfTheme {
                    Panel(
                        PanelModel(
                            state = state,
                            level = level,
                            noProfile = profile == null,
                            language = currentLanguage(),
                            languages = languages,
                            pending = pending,
                            message = message,
                        ),
                        PanelActions(
                            mic = ::onMic,
                            cancel = { app.session.cancel() },
                            language = { language = nextLanguage(languages, currentLanguage()) },
                            switchKeyboard = { switchToPreviousInputMethod() },
                            insert = ::insert,
                            copy = ::copy,
                            retry = ::retry,
                        ),
                    )
                }
            }
        }
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (attribute == null) tokens.finish() else tokens.start(attribute.packageName, attribute.fieldId, restarting)
    }

    override fun onFinishInput() {
        super.onFinishInput()
        tokens.finish()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        registry.currentState = Lifecycle.State.RESUMED
        message = null
        app.onOpen()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        app.session.stop()
        registry.currentState = Lifecycle.State.STARTED
    }

    override fun onDestroy() {
        app.session.stop()
        registry.currentState = Lifecycle.State.DESTROYED
        viewModelStore.clear()
        super.onDestroy()
    }

    override fun commit(text: String): Boolean = currentInputConnection?.commitText(text, 1) ?: false

    // The panel's choice if the profile still offers it, else the profile's default.
    private fun currentLanguage(): String {
        val profile = app.profile.value
        return language?.takeIf { it in profile?.languages.orEmpty() } ?: profile?.defaultLanguage ?: "en"
    }

    private fun onMic() {
        when (app.session.state.value) {
            is SessionState.Recording -> app.session.stop()
            is SessionState.Transcribing -> Unit
            else -> {
                // An IME cannot ask for a permission: the app screen does.
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    return
                }
                app.refreshProfileIfStale()
                message = try {
                    app.session.start(currentLanguage(), this)
                    null
                } catch (e: Exception) {
                    "Microphone: ${e.message}"
                }
            }
        }
    }

    private fun insert(draft: Draft) {
        message = if (app.session.deliver(draft, this)) null else "No field to type into"
        app.reloadPending()
    }

    private fun copy(draft: Draft) {
        val text = draft.text ?: return
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("dictation", text))
        message = "Copied"
    }

    private fun retry(draft: Draft) {
        message = "Transcribing…"
        app.scope.launch {
            val updated = app.session.retry(draft)
            message = if (updated.text != null) null else updated.error
            app.reloadPending()
        }
    }
}
