package com.mytv.my_tv

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.FileProvider
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Downloads an update in a foreground service, so it survives the app being
 * minimised or killed.
 *
 * Progress and the finished path are mirrored into SharedPreferences, which is
 * what lets the Dart side pick the download back up after the process has been
 * restarted. When it finishes, the notification carries an intent straight to
 * the package installer, so the update can be applied without reopening the
 * app at all.
 */
class UpdateDownloadService : Service() {

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_NAME = "name"

        private const val CHANNEL_ID = "updates"
        private const val NOTIFICATION_ID = 4711
        private const val PREFS = "mytv_update"

        const val STATE_IDLE = "idle"
        const val STATE_RUNNING = "running"
        const val STATE_DONE = "done"
        const val STATE_FAILED = "failed"

        fun status(context: Context): Map<String, Any?> {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val path = p.getString("path", null)
            // A file cleared out from under us counts as nothing downloaded.
            val stillThere = path != null && File(path).exists()
            return mapOf(
                "state" to when {
                    p.getString("state", STATE_IDLE) == STATE_DONE && !stillThere -> STATE_IDLE
                    else -> p.getString("state", STATE_IDLE)
                },
                "progress" to p.getInt("progress", 0),
                "path" to if (stillThere) path else null,
                "error" to p.getString("error", null),
            )
        }

        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .apply()
        }
    }

    private fun write(
        state: String,
        progress: Int = 0,
        path: String? = null,
        error: String? = null,
    ) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().apply {
            putString("state", state)
            putInt("progress", progress)
            putString("path", path)
            putString("error", error)
            apply()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val url = intent?.getStringExtra(EXTRA_URL)
        val name = intent?.getStringExtra(EXTRA_NAME) ?: "update.apk"
        if (url.isNullOrEmpty()) {
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        startForegroundCompat(buildProgressNotification(0))
        write(STATE_RUNNING, 0)

        thread(name = "my-tv-update-download") { download(url, name) }
        // Not sticky: a half-finished download is restarted by the user, not
        // silently resumed with stale arguments.
        return START_NOT_STICKY
    }

    private fun download(url: String, name: String) {
        val dir = File(cacheDir, "updates").apply { mkdirs() }
        val target = File(dir, name)
        val partial = File(dir, "$name.part")
        if (partial.exists()) partial.delete()

        var connection: HttpURLConnection? = null
        try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                connectTimeout = 30_000
                readTimeout = 30_000
                setRequestProperty("Accept", "*/*")
                connect()
            }

            if (connection.responseCode !in 200..299) {
                finishFailed("The server returned HTTP ${connection.responseCode}.")
                return
            }

            val total = connection.contentLengthLong
            var received = 0L
            var lastPercent = -1

            connection.inputStream.use { input ->
                partial.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                        received += read

                        if (total > 0) {
                            val percent = ((received * 100) / total).toInt()
                            if (percent != lastPercent) {
                                lastPercent = percent
                                write(STATE_RUNNING, percent)
                                notify(buildProgressNotification(percent))
                            }
                        }
                    }
                    output.flush()
                }
            }

            if (total > 0 && received < total) {
                partial.delete()
                finishFailed("The download ended early.")
                return
            }

            if (target.exists()) target.delete()
            partial.renameTo(target)
            finishDone(target)
        } catch (e: Exception) {
            partial.delete()
            finishFailed(e.message ?: e.toString())
        } finally {
            connection?.disconnect()
        }
    }

    private fun finishDone(file: File) {
        write(STATE_DONE, 100, file.absolutePath)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        notify(buildDoneNotification(file))
        stopSelf()
    }

    private fun finishFailed(message: String) {
        write(STATE_FAILED, 0, null, message)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        notify(buildFailedNotification(message))
        stopSelf()
    }

    // --- Notifications -------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "App updates",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Progress while a new version downloads." }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private fun base() = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.stat_sys_download)
        .setContentTitle("My TV")
        .setOnlyAlertOnce(true)

    private fun buildProgressNotification(percent: Int) = base()
        .setContentText("Downloading update… $percent%")
        .setProgress(100, percent, percent <= 0)
        .setOngoing(true)
        .build()

    private fun buildDoneNotification(file: File) = base()
        .setSmallIcon(android.R.drawable.stat_sys_download_done)
        .setContentText("Update downloaded — tap to install")
        .setAutoCancel(true)
        .setContentIntent(installIntent(file))
        .build()

    private fun buildFailedNotification(message: String) = base()
        .setSmallIcon(android.R.drawable.stat_notify_error)
        .setContentText("Update download failed")
        .setStyle(NotificationCompat.BigTextStyle().bigText(message))
        .setAutoCancel(true)
        .build()

    /** Opens the package installer straight from the notification. */
    private fun installIntent(file: File): PendingIntent {
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notify(notification: android.app.Notification) {
        // Without POST_NOTIFICATIONS on Android 13+ the notification is simply
        // suppressed; the service still runs and the download still finishes.
        if (NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            try {
                NotificationManagerCompat.from(this)
                    .notify(NOTIFICATION_ID, notification)
            } catch (_: SecurityException) {
                // Permission revoked between the check and the call.
            }
        }
    }

    private fun startForegroundCompat(notification: android.app.Notification) {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
    }
}
