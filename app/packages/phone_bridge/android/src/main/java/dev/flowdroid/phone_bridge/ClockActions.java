package dev.flowdroid.phone_bridge;

import android.content.Intent;
import android.content.Context;
import android.provider.AlarmClock;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.List;
import java.util.Map;

/** Alarms and timers in the phone's clock app. */
final class ClockActions {
    private ClockActions() {}

    /** `{opened: true}`, `{notified: true}` (tap to finish when in the background), or `{error}`. */
    static Map<String, Object> alarm(Context context, int hour, int minute, List<String> days, String label) {
        Intent set = new Intent(AlarmClock.ACTION_SET_ALARM)
            .putExtra(AlarmClock.EXTRA_HOUR, hour)
            .putExtra(AlarmClock.EXTRA_MINUTES, minute)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true);
        if (label != null && !label.isEmpty()) set.putExtra(AlarmClock.EXTRA_MESSAGE, label);
        if (days != null && !days.isEmpty()) {
            ArrayList<Integer> repeat = new ArrayList<>();
            for (String d : days) {
                int day = dayOf(d);
                if (day > 0) repeat.add(day);
            }
            set.putExtra(AlarmClock.EXTRA_DAYS, repeat);
        }
        String when = String.format(java.util.Locale.ROOT, "%02d:%02d", hour, minute);
        return DeviceActions.startOrNotify(context, set, "Tap to set the alarm", when + (label == null || label.isEmpty() ? "" : " · " + label));
    }

    static Map<String, Object> timer(Context context, int seconds, String label) {
        Intent set = new Intent(AlarmClock.ACTION_SET_TIMER)
            .putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            .putExtra(AlarmClock.EXTRA_SKIP_UI, true);
        if (label != null && !label.isEmpty()) set.putExtra(AlarmClock.EXTRA_MESSAGE, label);
        return DeviceActions.startOrNotify(context, set, "Tap to start the timer", seconds + " s" + (label == null || label.isEmpty() ? "" : " · " + label));
    }

    static Map<String, Object> showAlarms(Context context) {
        return DeviceActions.startOrNotify(context, new Intent(AlarmClock.ACTION_SHOW_ALARMS), "Tap to see your alarms", "");
    }

    private static int dayOf(String d) {
        switch (d) {
            case "sun": return Calendar.SUNDAY;
            case "mon": return Calendar.MONDAY;
            case "tue": return Calendar.TUESDAY;
            case "wed": return Calendar.WEDNESDAY;
            case "thu": return Calendar.THURSDAY;
            case "fri": return Calendar.FRIDAY;
            case "sat": return Calendar.SATURDAY;
            default: return 0;
        }
    }
}
