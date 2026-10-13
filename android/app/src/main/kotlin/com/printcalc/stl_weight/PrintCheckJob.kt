package com.printcalc.stl_weight

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Every ~15 minutes (Android decides exactly) runs the Dart entry point
 * `backgroundCheck` without UI: it asks the printers whether a print ended
 * and posts a notification. Skipped while the app is open (it watches itself).
 */
class PrintCheckJob : JobService() {
    private var engine: FlutterEngine? = null
    private var params: JobParameters? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onStartJob(p: JobParameters): Boolean {
        if (MainActivity.resumed) return false
        params = p
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
                        "backgroundDone" -> {
                            result.success(null)
                            main.post { finish(false) }
                        }
                        else -> result.notImplemented()
                    }
                }
                e.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundCheck")
                )
            } catch (t: Throwable) {
                finish(false)
            }
        }
        main.postDelayed({ finish(false) }, 90_000) // safety net
        return true
    }

    private fun finish(reschedule: Boolean) {
        val p = params ?: return
        params = null
        engine?.destroy()
        engine = null
        jobFinished(p, reschedule)
    }

    override fun onStopJob(p: JobParameters): Boolean {
        params = null
        engine?.destroy()
        engine = null
        return true
    }

    companion object {
        private const val JOB_ID = 7101

        fun schedule(context: Context, on: Boolean) {
            val js = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            if (!on) {
                js.cancel(JOB_ID)
                return
            }
            if (js.getPendingJob(JOB_ID) != null) return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, PrintCheckJob::class.java))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build()
            try {
                js.schedule(job)
            } catch (e: Exception) {
                // Some ROMs refuse persisted jobs; try without surviving reboots.
                js.schedule(
                    JobInfo.Builder(JOB_ID, ComponentName(context, PrintCheckJob::class.java))
                        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                        .setPeriodic(15 * 60 * 1000L)
                        .build()
                )
            }
        }
    }
}
