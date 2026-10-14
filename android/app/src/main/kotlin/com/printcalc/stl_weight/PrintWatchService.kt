package com.printcalc.stl_weight

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Runs while a print is in progress: keeps a live connection to the printers
 * (Dart entry point `printWatchService`) so the "print finished" notification
 * comes right away, even with the app closed and the phone asleep.
 * Shows an ongoing "Printing… 45%" notification and stops itself when idle.
 */
class PrintWatchService : Service() {
    private var engine: FlutterEngine? = null
    private var wake: PowerManager.WakeLock? = null
    private val main = Handler(Looper.getMainLooper())
    private var text = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopAll()
            return START_NOT_STICKY
        }
        try {
            val n = build(if (text.isEmpty()) getString(R.string.app_name) else text)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, n)
            }
        } catch (e: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (wake == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kotushka:printwatch").apply {
                setReferenceCounted(false)
                acquire(24 * 60 * 60 * 1000L)
            }
        }
        if (engine == null) startEngine()
        return START_STICKY
    }

    private fun startEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationCompleteAsync(applicationContext, null, main) {
            try {
                val e = FlutterEngine(applicationContext)
                engine = e
                MethodChannel(e.dartExecutor.binaryMessenger, "stl_weight/files").setMethodCallHandler { call, result ->
                    when (call.method) {
                        "filesDir" -> result.success(filesDir.absolutePath)
                        "notifyNow" -> {
                            val i = Intent(this, ReminderReceiver::class.java)
                                .putExtra("id", call.argument<Int>("id") ?: 1)
                                .putExtra("title", call.argument<String>("title") ?: "")
                                .putExtra("text", call.argument<String>("text") ?: "")
                                .putExtra("kind", call.argument<String>("kind") ?: "")
                            ReminderReceiver().onReceive(this, i)
                            result.success(true)
                        }
                        "appResumed" -> result.success(MainActivity.resumed)
                        "printServiceText" -> {
                            text = call.argument<String>("text") ?: ""
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            try {
                                nm.notify(NOTIFICATION_ID, build(text))
                            } catch (_: SecurityException) {
                            }
                            result.success(true)
                        }
                        "stopPrintService" -> {
                            result.success(true)
                            main.post { stopAll() }
                        }
                        "schedulePrintWatch", "startPrintService" -> result.success(true)
                        else -> result.notImplemented()
                    }
                }
                e.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "printWatchService")
                )
            } catch (t: Throwable) {
                stopAll()
            }
        }
    }

    private fun build(text: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Принтери: друк триває", NotificationManager.IMPORTANCE_LOW).apply {
                    setShowBadge(false)
                }
            )
        }
        val open = PendingIntent.getActivity(
            this, NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return b.setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun stopAll() {
        engine?.destroy()
        engine = null
        try {
            wake?.release()
        } catch (_: Exception) {
        }
        wake = null
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        engine?.destroy()
        engine = null
        try {
            wake?.release()
        } catch (_: Exception) {
        }
        wake = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "printing"
        private const val NOTIFICATION_ID = 7102
        private const val ACTION_STOP = "stop"

        /** Starts the watcher; false when Android does not allow it right now. */
        fun start(context: Context): Boolean = try {
            val i = Intent(context, PrintWatchService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
            true
        } catch (e: Exception) {
            false // background start not allowed (battery optimisation on)
        }
    }
}
