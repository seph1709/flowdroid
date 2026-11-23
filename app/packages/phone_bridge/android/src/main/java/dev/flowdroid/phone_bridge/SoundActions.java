package dev.flowdroid.phone_bridge;

import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.provider.Settings;

import java.util.HashMap;
import java.util.Map;

/** The ringer mode and Do Not Disturb. */
final class SoundActions {
    private SoundActions() {}

    /** Whether the person allowed FlowDroid to change Do Not Disturb (needed for silent and DND). */
    static boolean dndAccess(Context context) {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        return nm != null && nm.isNotificationPolicyAccessGranted();
    }

    static void openDndAccess(Context context) {
        context.startActivity(new Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }

    /** `{ringer, dnd}` as they are now. */
    static Map<String, Object> current(Context context) {
        AudioManager audio = context.getSystemService(AudioManager.class);
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        Map<String, Object> out = new HashMap<>();
        int ringer = audio == null ? AudioManager.RINGER_MODE_NORMAL : audio.getRingerMode();
        out.put("ringer", ringer == AudioManager.RINGER_MODE_SILENT ? "silent"
            : ringer == AudioManager.RINGER_MODE_VIBRATE ? "vibrate" : "normal");
        int filter = nm == null ? NotificationManager.INTERRUPTION_FILTER_ALL : nm.getCurrentInterruptionFilter();
        out.put("dnd", filter == NotificationManager.INTERRUPTION_FILTER_NONE ? "on"
            : filter == NotificationManager.INTERRUPTION_FILTER_PRIORITY ? "priority"
            : filter == NotificationManager.INTERRUPTION_FILTER_ALARMS ? "alarms" : "off");
        return out;
    }

    /** Sets [mode] and returns the state before, or `{error}`. */
    static Map<String, Object> set(Context context, String mode) {
        Map<String, Object> before = current(context);
        if ("read".equals(mode)) return before;
        AudioManager audio = context.getSystemService(AudioManager.class);
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        boolean needsAccess = !"vibrate".equals(mode) && !"normal".equals(mode);
        if (needsAccess && !dndAccess(context)) {
            return error("allow FlowDroid to change Do Not Disturb first: Settings → Phone access → Do Not Disturb");
        }
        try {
            switch (mode) {
                case "silent": audio.setRingerMode(AudioManager.RINGER_MODE_SILENT); break;
                case "vibrate": audio.setRingerMode(AudioManager.RINGER_MODE_VIBRATE); break;
                case "normal": audio.setRingerMode(AudioManager.RINGER_MODE_NORMAL); break;
                case "dndOn": nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_NONE); break;
                case "dndPriority": nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_PRIORITY); break;
                case "dndAlarms": nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALARMS); break;
                case "dndOff": nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALL); break;
                default: return error("unknown sound mode " + mode);
            }
        } catch (SecurityException e) {
            // Leaving silent while Do Not Disturb is on also needs access.
            return error("Android needs Do Not Disturb access for this: Settings → Phone access → Do Not Disturb");
        } catch (RuntimeException e) {
            return error("could not change the sound mode: " + e.getMessage());
        }
        return before;
    }

    private static Map<String, Object> error(String message) {
        Map<String, Object> out = new HashMap<>();
        out.put("error", message);
        return out;
    }
}
