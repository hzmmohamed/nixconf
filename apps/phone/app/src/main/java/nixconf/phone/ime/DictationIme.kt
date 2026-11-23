package nixconf.phone.ime

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import nixconf.phone.AppServices
import nixconf.phone.drafts.Draft
import nixconf.phone.session.DictationSession
import nixconf.phone.session.EditorTarget
import nixconf.phone.session.SessionState
import nixconf.phone.session.StartException
import nixconf.phone.ui.MainActivity
import nixconf.phone.ui.NixconfTheme

/**
 * The dictation keyboard: a Compose panel (Panel.kt) over the shared
 * dictation session. It is the session's [EditorTarget]: the token names the
 * focused input session ([InputTokens]) and changes when the user moves on,
 * so text transcribed after a switch is kept as a draft instead of typed;
 * composing text (stream mode) is removed from a field the user leaves.
 * Hiding or destroying the keyboard stops a recording (never records unseen).
 * Password fields get no dictation (nothing of them reaches a draft); number,
 * phone and date fields a warning; incognito fields keep no draft once typed.
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
    private var notice by mutableStateOf<Notice?>(null)

    // The focused field (onStartInput).
    private var kind by mutableStateOf(FieldKind.TEXT)
    private var incognitoField by mutableStateOf(false)
    private var enter by mutableStateOf<Int?>(null)

    // Keyboard tapped while finishing: switch once the text is typed.
    private var switchQueued by mutableStateOf(false)
    private var retrying by mutableStateOf(emptySet<String>())
    private var stateJob: Job? = null

    private val tokens = InputTokens()
    override val token: String? get() = tokens.token
    override val incognito: Boolean get() = incognitoField
    override val composable: Boolean get() = kind == FieldKind.TEXT && !incognitoField

    // Composing text of ours is showing in the current field.
    private var composing = false

    override fun onCreate() {
        super.onCreate()
        savedState.performRestore(null)
        registry.currentState = Lifecycle.State.CREATED
        app = AppServices.of(this)
        stateJob = app.scope.launch { app.session.state.collect(::onState) }
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
                            notice = notice,
                            field = kind,
                            incognito = incognitoField,
                            enterLabel = enterLabel(enter),
                            switchQueued = switchQueued,
                            retrying = retrying,
                        ),
                        PanelActions(
                            mic = ::onMic,
                            cancel = { app.session.cancel() },
                            language = { language = nextLanguage(languages, currentLanguage()) },
                            switchKeyboard = ::onSwitchKeyboard,
                            insert = ::insert,
                            copy = ::copy,
                            retry = ::retry,
                            delete = { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) },
                            enter = ::onEnter,
                        ),
                    )
                }
            }
        }
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (attribute == null) tokens.finish() else tokens.start(attribute.packageName, attribute.fieldId, restarting)
        kind = attribute?.let { fieldKind(it.inputType) } ?: FieldKind.TEXT
        incognitoField = attribute?.let { incognito(it.imeOptions) } ?: false
        enter = attribute?.let { enterAction(it.imeOptions) }
    }

    override fun onFinishInput() {
        // The default finishes (keeps) composing text: a session's unfinished
        // text must not stay in a field the user left.
        if (composing) currentInputConnection?.setComposingText("", 1)
        composing = false
        super.onFinishInput()
        tokens.finish()
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        registry.currentState = Lifecycle.State.RESUMED
        notice = null
        // Another field: the last result is not for it (a pending draft with text stays offered).
        if (!restarting) app.session.newInput()
        app.onOpen()
    }

    // Landscape too: no extract mode (a big plain edit box above the panel).
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        app.session.stop()
        registry.currentState = Lifecycle.State.STARTED
    }

    override fun onDestroy() {
        stateJob?.cancel()
        app.session.stop()
        registry.currentState = Lifecycle.State.DESTROYED
        viewModelStore.clear()
        super.onDestroy()
    }

    override fun commit(text: String): Boolean = (currentInputConnection?.commitText(text, 1) ?: false).also {
        if (it) composing = false
    }

    override fun compose(text: String): Boolean {
        val ic = currentInputConnection ?: return false
        if (!ic.setComposingText(text, 1)) return false
        if (text.isEmpty()) ic.finishComposingText()
        composing = text.isNotEmpty()
        return true
    }

    // The panel's choice if the profile still offers it, else the profile's default.
    private fun currentLanguage(): String {
        val profile = app.profile.value
        return language?.takeIf { it in profile?.languages.orEmpty() } ?: profile?.defaultLanguage ?: "en"
    }

    private fun onMic() {
        when (app.session.state.value) {
            is SessionState.Recording -> app.session.stop()
            is SessionState.Finishing -> Unit
            else -> {
                if (kind == FieldKind.PASSWORD) return
                // An IME cannot ask for a permission: the app screen does.
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    return
                }
                app.refreshProfileIfStale()
                notice = try {
                    app.session.start(currentLanguage(), this)
                    null
                } catch (e: StartException) {
                    Notice(startError(e.storage, e.message), error = true)
                }
            }
        }
    }

    // While finishing, switching now would end the input and turn the text
    // into a "field changed" draft: the switch waits for it instead (tap
    // again to stay). Recording: the button is off.
    private fun onSwitchKeyboard() {
        if (app.session.state.value is SessionState.Finishing) {
            switchQueued = !switchQueued
        } else {
            switchKeyboard()
        }
    }

    private fun onState(state: SessionState) {
        if (!switchQueued) return
        when (state) {
            is SessionState.Done -> {
                switchQueued = false
                switchKeyboard()
            }
            is SessionState.Recording, is SessionState.Finishing -> Unit
            // A draft (or cancelled): stay, so the user sees what happened.
            else -> switchQueued = false
        }
    }

    private fun switchKeyboard() = switchAway(
        previous = ::switchToPreviousInputMethod,
        next = { switchToNextInputMethod(false) },
        picker = { getSystemService(InputMethodManager::class.java).showInputMethodPicker() },
    )

    // The editor's action (Send, Search, …) or a newline.
    private fun onEnter() {
        val action = enter
        if (action != null) {
            currentInputConnection?.performEditorAction(action)
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun insert(draft: Draft) {
        notice = deliveryText(app.session.deliver(draft, this))?.let { Notice(it, error = true) }
        app.reloadPending()
    }

    private fun copy(draft: Draft) {
        val text = draft.text ?: return
        getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("dictation", text))
        notice = Notice("Copied")
    }

    // Transcribes a draft and types it here, if the user is still in the
    // field the tap came from (else it stays listed, with its text).
    private fun retry(draft: Draft) {
        if (draft.id in retrying) return
        retrying = retrying + draft.id
        notice = null
        val tapped = tokens.token
        app.scope.launch {
            val updated = app.session.retry(draft)
            retrying = retrying - draft.id
            notice = when {
                updated.text == null -> Notice(keptText(updated.error ?: DictationSession.NO_SERVER), error = true)
                tapped != null && tapped == tokens.token && kind != FieldKind.PASSWORD ->
                    deliveryText(app.session.deliver(updated, this@DictationIme))?.let { Notice(it, error = true) }
                else -> null
            }
            app.reloadPending()
        }
    }
}
