package com.printcalc.stl_weight

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Fires at the expected end of a print and starts one printer check right
 * away, so "print finished" comes on time without anything in the shade.
 * The check reschedules it if the print is still running.
 */
class PrintAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!MainActivity.resumed) PrintCheckJob.runNow(context)
    }

    companion object {
        private const val REQUEST = 7104

        fun schedule(context: Context, atMillis: Long) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val p = PendingIntent.getBroadcast(
                context, REQUEST, Intent(context, PrintAlarmReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            if (atMillis <= 0) {
                am.cancel(p)
                return
            }
            try {
                val exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()
                when {
                    exact && Build.VERSION.SDK_INT >= 23 -> am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, p)
                    Build.VERSION.SDK_INT >= 23 -> am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, p)
                    else -> am.setExact(AlarmManager.RTC_WAKEUP, atMillis, p)
                }
            } catch (e: SecurityException) {
                if (Build.VERSION.SDK_INT >= 23) am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, p)
            }
        }
    }
}
