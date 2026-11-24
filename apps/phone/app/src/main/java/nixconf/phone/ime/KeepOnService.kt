package nixconf.phone.ime

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import nixconf.phone.AppServices
import nixconf.phone.R
import nixconf.phone.session.SessionState

/**
 * Keeps a recording going while the keyboard is closed (Keep on): a
 * microphone foreground service, so Android neither silences the mic nor
 * freezes the process, with an ongoing notification (Stop, Cancel). It
 * follows the session and ends with it, or when Keep on is turned off; the
 * session itself does the work, as with the keyboard open.
 */
class KeepOnService : Service() {
    private lateinit var app: AppServices
    private var stateJob: Job? = null

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        app = AppServices.of(this)
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Recording in the background", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> app.session.stop()
            ACTION_CANCEL -> app.session.cancel()
            else -> try {
                startForeground(ID, notification(app.session.state.value), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } catch (e: Exception) {
                // No while-in-use mic access (the keyboard was hidden): it stops with the keyboard.
                app.session.keepOn(false)
            }
        }
        if (stateJob == null) {
            stateJob = app.scope.launch {
                app.session.state.collect { state ->
                    if (app.session.background) {
                        getSystemService(NotificationManager::class.java).notify(ID, notification(state))
                    } else {
                        stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stateJob?.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    private fun notification(state: SessionState): Notification {
        val builder = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_mic)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        if (state is SessionState.Recording) {
            builder.setContentTitle("Dictating")
                .setContentText("Stop to transcribe into the field it started in")
                .setWhen(state.startedMs)
                .setUsesChronometer(true)
                .addAction(action("Stop", ACTION_STOP))
        } else {
            builder.setContentTitle(if (state is SessionState.Finishing) finishingText(state) else "Dictation")
                .setShowWhen(false)
        }
        return builder.addAction(action("Cancel", ACTION_CANCEL)).build()
    }

    private fun action(title: String, action: String): Notification.Action {
        val intent = Intent(this, KeepOnService::class.java).setAction(action)
        val pending = PendingIntent.getService(this, action.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE)
        return Notification.Action.Builder(null, title, pending).build()
    }

    companion object {
        private const val CHANNEL = "keep_on"
        private const val ID = 1
        private const val ACTION_STOP = "nixconf.phone.keepon.STOP"
        private const val ACTION_CANCEL = "nixconf.phone.keepon.CANCEL"

        /** Starts the service; false if Android refuses (only a visible keyboard may). */
        fun start(context: Context): Boolean = try {
            context.startForegroundService(Intent(context, KeepOnService::class.java))
            true
        } catch (e: ForegroundServiceStartNotAllowedException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }
}
