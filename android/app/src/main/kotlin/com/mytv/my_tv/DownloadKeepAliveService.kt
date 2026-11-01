package com.mytv.my_tv

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * Keeps the process alive while films are being saved for offline.
 *
 * The transfer itself runs in Dart, which works well — it was measured at
 * 8 MB/s against a real provider. What it cannot do alone is survive the app
 * being backgrounded: Android is free to kill the process, and the download
 * dies with it. A foreground service is what makes the process ineligible for
 * that, and the notification it requires doubles as the progress indicator.
 *
 * It holds no download logic of its own on purpose. Reimplementing the
 * transfer here would mean two copies of the resume, retry and file handling
 * to keep in step.
 */
class DownloadKeepAliveService : Service() {

    companion object {
        const val ACTION_START = "com.mytv.my_tv.KEEP_ALIVE_START"
        const val ACTION_UPDATE = "com.mytv.my_tv.KEEP_ALIVE_UPDATE"
        const val ACTION_STOP = "com.mytv.my_tv.KEEP_ALIVE_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PERCENT = "percent"

        private const val CHANNEL_ID = "downloads"
        private const val NOTIFICATION_ID = 4712
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_UPDATE -> {
                notify(
                    intent.getStringExtra(EXTRA_TITLE) ?: "",
                    intent.getIntExtra(EXTRA_PERCENT, -1),
                )
                return START_STICKY
            }

            else -> {
                createChannel()
                startForegroundCompat(
                    build(
                        intent?.getStringExtra(EXTRA_TITLE) ?: "",
                        intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1,
                    ),
                )
                return START_STICKY
            }
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Offline downloads",
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = "Progress while a film is saved to this device." }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    /** Tapping the notification returns to the app rather than doing nothing. */
    private fun openApp(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun build(title: String, percent: Int) =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(if (title.isBlank()) "Saving for offline" else title)
            .setContentText(
                if (percent in 0..100) "Downloading… $percent%" else "Downloading…",
            )
            .setProgress(100, percent.coerceAtLeast(0), percent !in 0..100)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp())
            .build()

    private fun notify(title: String, percent: Int) {
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) return
        try {
            NotificationManagerCompat.from(this)
                .notify(NOTIFICATION_ID, build(title, percent))
        } catch (_: SecurityException) {
            // Permission revoked between the check and the call.
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
