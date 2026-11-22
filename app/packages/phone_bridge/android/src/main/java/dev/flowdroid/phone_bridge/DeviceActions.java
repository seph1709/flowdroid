package dev.flowdroid.phone_bridge;

import android.app.ActivityManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.net.Uri;
import android.os.Build;
import android.os.VibrationAttributes;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.provider.Settings;

import java.util.HashMap;
import java.util.Map;

/**
 * Phone actions that Android restricts for apps that aren't on screen, done the
 * way Android still allows them, or reported plainly when it doesn't.
 */
final class DeviceActions {
    private static final String LINKS_CHANNEL = "workflow_links";
    private static int nextLinkId = 9000;

    private DeviceActions() {}

    /** Whether FlowDroid's screen is showing (the service alone doesn't count). */
    static boolean onScreen() {
        ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
        ActivityManager.getMyMemoryState(info);
        return info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND;
    }

    /**
     * Android ignores vibration from background apps unless it is an alarm, so
     * workflows vibrate as one; it still respects the phone's vibration settings.
     */
    static String vibrate(Context context, long ms) {
        Vibrator vibrator;
        if (Build.VERSION.SDK_INT >= 31) {
            VibratorManager manager = context.getSystemService(VibratorManager.class);
            vibrator = manager == null ? null : manager.getDefaultVibrator();
        } else {
            vibrator = context.getSystemService(Vibrator.class);
        }
        if (vibrator == null || !vibrator.hasVibrator()) return "this phone has no vibration motor";
        VibrationEffect effect = VibrationEffect.createOneShot(Math.max(1, ms), VibrationEffect.DEFAULT_AMPLITUDE);
        if (Build.VERSION.SDK_INT >= 33) {
            vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM));
        } else {
            vibrator.vibrate(effect, new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());
        }
        return null;
    }

    /**
     * Opens [url] when Android allows it (FlowDroid on screen, or allowed to
     * "display over other apps"); otherwise posts a notification that opens it on tap.
     * Returns {opened: true} or {notified: true}, or {error}.
     */
    static Map<String, Object> openUrl(Context context, String url) {
        Map<String, Object> out = new HashMap<>();
        Intent view = new Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (onScreen() || Settings.canDrawOverlays(context)) {
            try {
                context.startActivity(view);
                out.put("opened", true);
                return out;
            } catch (android.content.ActivityNotFoundException e) {
                out.put("error", "no app can open " + url);
                return out;
            } catch (RuntimeException e) {
                // Blocked after all: fall back to the notification.
            }
        }
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null || !nm.areNotificationsEnabled()) {
            out.put("error", "Android doesn't let apps in the background open links, and notifications are off");
            return out;
        }
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(
                LINKS_CHANNEL, "Links from workflows", NotificationManager.IMPORTANCE_HIGH));
        }
        PendingIntent tap = PendingIntent.getActivity(
            context, nextLinkId, view, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        int icon = context.getResources().getIdentifier("ic_stat_flow", "drawable", context.getPackageName());
        android.app.Notification.Builder b = Build.VERSION.SDK_INT >= 26
            ? new android.app.Notification.Builder(context, LINKS_CHANNEL)
            : new android.app.Notification.Builder(context);
        b.setSmallIcon(icon != 0 ? icon : context.getApplicationInfo().icon)
            .setContentTitle("Tap to open")
            .setContentText(url)
            .setContentIntent(tap)
            .setAutoCancel(true);
        nm.notify(nextLinkId++, b.build());
        out.put("notified", true);
        return out;
    }

    static void clipboardWrite(Context context, String text) {
        ClipboardManager cm = context.getSystemService(ClipboardManager.class);
        if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("FlowDroid", text == null ? "" : text));
    }

    /** The clipboard text; Android 10+ only shows it to the app on screen. */
    static Map<String, Object> clipboardRead(Context context) {
        Map<String, Object> out = new HashMap<>();
        if (Build.VERSION.SDK_INT >= 29 && !onScreen()) {
            out.put("error", "Android only lets the app on screen read the clipboard, so this step works only while FlowDroid is open");
            return out;
        }
        ClipboardManager cm = context.getSystemService(ClipboardManager.class);
        ClipData clip = cm == null ? null : cm.getPrimaryClip();
        CharSequence text = clip == null || clip.getItemCount() == 0 ? null : clip.getItemAt(0).coerceToText(context);
        out.put("text", text == null ? "" : text.toString());
        return out;
    }
}
