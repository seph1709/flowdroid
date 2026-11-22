package dev.flowdroid.phone_bridge;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

/**
 * Brings FlowDroid's background service back when Android (or a phone maker's
 * battery manager) has stopped or frozen it, and keeps an alarm set for the
 * next scheduled run so schedules don't depend on a timer inside a paused app.
 */
final class Wake {
    private static final String TAG = "FlowDroidWake";
    /** flutter_foreground_task's receiver: it restarts the service unless the user turned it off. */
    private static final String RESTART_RECEIVER = "com.pravera.flutter_foreground_task.service.RestartReceiver";
    private static final int ALARM_REQUEST = 7201;

    private Wake() {}

    /** Restarts the service when no FlowDroid engine has been seen alive in the last few seconds. */
    static void ensureRunning(Context context) {
        if (Events.dartAlive(context)) return;
        restartService(context);
    }

    /**
     * Asks the service to start again. Does nothing when "Keep running" is off or the
     * service already runs. Android allows this from the background because FlowDroid
     * is exempt from battery optimization.
     */
    static void restartService(Context context) {
        try {
            Intent intent = new Intent().setComponent(new ComponentName(context.getPackageName(), RESTART_RECEIVER));
            context.sendBroadcast(intent);
        } catch (RuntimeException e) {
            Log.w(TAG, "could not ask the service to restart", e);
        }
    }

    /** Whether Android lets FlowDroid set exact alarms (always before Android 12). */
    static boolean canScheduleExact(Context context) {
        if (Build.VERSION.SDK_INT < 31) return true;
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        return alarms != null && alarms.canScheduleExactAlarms();
    }

    /** Sets (or with [atMillis] <= 0 clears) the one wake-up alarm. Returns whether it is exact. */
    static boolean setAlarm(Context context, long atMillis) {
        AlarmManager alarms = context.getSystemService(AlarmManager.class);
        if (alarms == null) return false;
        Intent intent = new Intent(context, WakeAlarm.class);
        PendingIntent pending = PendingIntent.getBroadcast(
            context, ALARM_REQUEST, intent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        if (atMillis <= 0) {
            alarms.cancel(pending);
            return false;
        }
        boolean exact = canScheduleExact(context);
        try {
            if (exact) {
                // Fires on time even in Doze; the phone may still batch it by a few seconds.
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending);
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending);
            }
        } catch (SecurityException e) {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending);
            exact = false;
        }
        return exact;
    }
}
