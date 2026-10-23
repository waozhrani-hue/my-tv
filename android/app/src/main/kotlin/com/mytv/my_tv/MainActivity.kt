package com.mytv.my_tv

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Adds the one thing the update flow cannot do from Dart: handing a
 * downloaded APK to the system package installer.
 *
 * Nothing here installs anything by itself. It opens the installer, which
 * shows its own confirmation, and on Android 8 and later the user must also
 * have allowed this app to request installs.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.mytv.my_tv/installer"
        const val APK_MIME = "application/vnd.android.package-archive"
        const val NOTIFICATION_REQUEST = 7311
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestInstalls" -> result.success(canRequestInstalls())

                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }

                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("no_path", "A path to the APK is required.", null)
                        } else {
                            runCatching { installApk(path) }
                                .onSuccess { result.success(true) }
                                .onFailure { result.error("install_failed", it.message, null) }
                        }
                    }

                    "startBackgroundDownload" -> {
                        val url = call.argument<String>("url")
                        val name = call.argument<String>("name") ?: "update.apk"
                        if (url.isNullOrEmpty()) {
                            result.error("no_url", "A download URL is required.", null)
                        } else {
                            runCatching { startDownloadService(url, name) }
                                .onSuccess { result.success(true) }
                                .onFailure { result.error("start_failed", it.message, null) }
                        }
                    }

                    "downloadStatus" ->
                        result.success(UpdateDownloadService.status(this))

                    "clearDownloadStatus" -> {
                        UpdateDownloadService.clear(this)
                        result.success(null)
                    }

                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /** Before Android 8 the permission is granted at install time. */
    private fun canRequestInstalls(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
        } else {
            // Older releases expose it as a single global switch.
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /** Hands the transfer to a foreground service so it outlives this screen. */
    private fun startDownloadService(url: String, name: String) {
        val intent = Intent(this, UpdateDownloadService::class.java).apply {
            putExtra(UpdateDownloadService.EXTRA_URL, url)
            putExtra(UpdateDownloadService.EXTRA_NAME, name)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /**
     * Asks for POST_NOTIFICATIONS on Android 13+. Only the progress
     * notification depends on it — the download runs either way.
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) return
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST,
        )
    }

    private fun installApk(path: String) {
        val file = File(path)
        require(file.exists()) { "The downloaded file is no longer at $path." }

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
