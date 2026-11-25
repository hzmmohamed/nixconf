package nixconf.phone

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import nixconf.phone.audio.Recorder
import nixconf.phone.drafts.Draft
import nixconf.phone.drafts.DraftStore
import nixconf.phone.engine.LocalEngine
import nixconf.phone.engine.PowerClient
import nixconf.phone.engine.SileroVad
import nixconf.phone.engine.Where
import nixconf.phone.engine.WhisperClient
import nixconf.phone.model.ModelDownloader
import nixconf.phone.profile.Profile
import nixconf.phone.profile.ProfileStore
import nixconf.phone.session.DictationSession
import nixconf.phone.session.SessionState
import nixconf.phone.update.Updater
import nixconf.phone.update.installApk
import okhttp3.OkHttpClient
import okhttp3.Request

sealed interface ModelStatus {
    data object NoProfile : ModelStatus
    data object Ready : ModelStatus
    data class Missing(val error: String?) : ModelStatus
    data class Downloading(val done: Long, val total: Long) : ModelStatus
}

/**
 * What the keyboard and the app screen share (one process, one instance): the
 * profile, drafts, the dictation session and the on-phone model. Everything
 * runs on [scope] (main thread, lives as long as the process): no background
 * jobs, the work happens while the keyboard or the app is open (or while a
 * recording kept on runs, held by KeepOnService).
 */
class AppServices private constructor(context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).build()

    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)

    var profileUrl: String
        get() = prefs.getString(KEY_PROFILE_URL, null) ?: ProfileStore.DEFAULT_URL
        set(value) = prefs.edit().putString(KEY_PROFILE_URL, value.trim()).apply()

    private val mutableWhere = MutableStateFlow(Where.of(prefs.getString(KEY_WHERE, null)))

    /** The keyboard's Auto / Phone toggle (kept until changed). */
    val where: StateFlow<Where> = mutableWhere.asStateFlow()

    fun setWhere(value: Where) {
        prefs.edit().putString(KEY_WHERE, value.name).apply()
        mutableWhere.value = value
    }

    private val profileDir = File(context.filesDir, "profile")
    private val profiles = ProfileStore(profileDir, ::fetchText, System::currentTimeMillis)
    private val mutableProfile = MutableStateFlow(profiles.cached())
    val profile: StateFlow<Profile?> = mutableProfile.asStateFlow()

    /** When the cached profile was last fetched (0: never). */
    fun profileFetchedMs(): Long = File(profileDir, "profile.json").lastModified()

    val drafts = DraftStore(File(context.filesDir, "drafts"), System::currentTimeMillis)
    val whisper = WhisperClient(http)
    private val power = PowerClient(http)
    val models = ModelDownloader(http, File(context.filesDir, "models"), ::isUnmetered)
    val recorder = Recorder()
    val local = LocalEngine(
        modelDir = { profile.value?.localModel?.takeIf(models::isReady)?.let(models::modelDir) },
        scope = scope,
    )
    val session = DictationSession(
        profile = { profile.value },
        drafts = drafts,
        audio = recorder,
        remote = whisper,
        local = local,
        probe = { whisper.probe(it) },
        scope = scope,
        onBattery = { power.onBattery(it) },
        where = { where.value },
        // Segments need the VAD model (in the APK's assets); without it, whole recordings.
        vad = context.assets.takeIf(SileroVad::bundled)?.let { assets -> { SileroVad(assets) } },
    )

    val updater = Updater(http, File(context.cacheDir, "updates")) { installApk(context, it) }

    private val mutablePending = MutableStateFlow<List<Draft>>(emptyList())

    /** Pending drafts, oldest first, without the one being recorded. */
    val pending: StateFlow<List<Draft>> = mutablePending.asStateFlow()

    private val mutableModelStatus = MutableStateFlow<ModelStatus>(ModelStatus.NoProfile)
    val modelStatus: StateFlow<ModelStatus> = mutableModelStatus.asStateFlow()

    private var openJob: Job? = null
    private var downloadJob: Job? = null

    init {
        scope.launch {
            session.state.collect { if (it is SessionState.Done || it is SessionState.Kept) reloadPending() }
        }
    }

    /**
     * On keyboard show and app resume: refresh the profile (if older than an
     * hour, or [force]), prune old drafts, start the model download if it is
     * missing, and transcribe pending drafts if a server answers.
     */
    fun onOpen(force: Boolean = false): Job {
        openJob?.takeIf { it.isActive }?.let { return it }
        return scope.launch {
            val p = withContext(Dispatchers.IO) {
                profiles.refreshIfStale(profileUrl, if (force) 0 else PROFILE_MAX_AGE_MS)
            }
            mutableProfile.value = p
            withContext(Dispatchers.IO) { drafts.prune(p?.keepDays ?: 7) }
            refreshModelStatus()
            if (mutableModelStatus.value is ModelStatus.Missing) downloadModel(force = false)
            loadPending()
            // Not part of this job: Test waits for the profile, not for transcriptions.
            retryPending(p)
        }.also { openJob = it }
    }

    /** At mic press: a stale profile is refetched in the background; the session uses what is cached. */
    fun refreshProfileIfStale() {
        onOpen()
    }

    fun reloadPending() {
        scope.launch { loadPending() }
    }

    private suspend fun loadPending() {
        // The draft being recorded is skipped before it is loaded: loading repairs the WAV header.
        val list = withContext(Dispatchers.IO) { drafts.pending { it == session.activeDraftId } }
        mutablePending.value = list.filter { it.id != session.activeDraftId }
    }

    /** Fetches the on-phone model; [force] also on mobile data ("Download now"). */
    fun downloadModel(force: Boolean) {
        val model = profile.value?.localModel ?: return
        if (downloadJob?.isActive == true) return
        downloadJob = scope.launch {
            mutableModelStatus.value = ModelStatus.Downloading(0, model.files.sumOf { it.size })
            val result = models.download(model, force) { done, total ->
                mutableModelStatus.value = ModelStatus.Downloading(done, total)
            }
            mutableModelStatus.value = result.fold({ ModelStatus.Ready }, { ModelStatus.Missing(it.message) })
        }
    }

    private suspend fun refreshModelStatus() {
        if (downloadJob?.isActive == true) return
        val model = profile.value?.localModel
        mutableModelStatus.value = when {
            model == null -> ModelStatus.NoProfile
            withContext(Dispatchers.IO) { models.isReady(model) } -> ModelStatus.Ready
            else -> (mutableModelStatus.value as? ModelStatus.Missing) ?: ModelStatus.Missing(null)
        }
    }

    // Only drafts without text (those kept for "field changed" have theirs:
    // they are offered, not transcribed again); a draft a server already
    // heard nothing in is left alone. Only while no session runs, which
    // cancels it (DictationSession.retryWhenIdle).
    private fun retryPending(p: Profile?) {
        if (p == null) return
        val todo = pending.value.filter {
            it.text == null && it.error != DictationSession.NOTHING_HEARD && it.id != session.activeDraftId
        }
        if (todo.isEmpty()) return
        session.retryWhenIdle(todo)?.invokeOnCompletion { reloadPending() }
    }

    private fun isUnmetered(): Boolean {
        val caps = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    private fun fetchText(url: String): String {
        val client = http.newBuilder().callTimeout(10, TimeUnit.SECONDS).build()
        return client.newCall(Request.Builder().url(url).build()).execute().use {
            if (!it.isSuccessful) throw IOException("$url: HTTP ${it.code}")
            it.body?.string() ?: throw IOException("$url: empty answer")
        }
    }

    companion object {
        private const val KEY_PROFILE_URL = "profileUrl"
        private const val KEY_WHERE = "transcribeOn"
        private const val PROFILE_MAX_AGE_MS = 3_600_000L

        @Volatile private var instance: AppServices? = null

        fun of(context: Context): AppServices = instance ?: synchronized(this) {
            instance ?: AppServices(context.applicationContext).also { instance = it }
        }
    }
}
