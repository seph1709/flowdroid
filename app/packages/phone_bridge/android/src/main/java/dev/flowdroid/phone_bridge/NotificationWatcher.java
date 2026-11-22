package dev.flowdroid.phone_bridge;

import android.app.Notification;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONException;
import org.json.JSONObject;

/** Saves other apps' notifications as events for the Notification Trigger (once the user grants access). */
public class NotificationWatcher extends NotificationListenerService {
    /** Apps re-post one notification many times (progress, grouping, a second alert); report it once. */
    private static final long REPEAT_MS = 10_000;
    private static final long HIDDEN_REPEAT_MS = 1_500;
    private static final long STALE_MS = 5 * 60_000;
    private static final java.util.LinkedHashMap<String, Long> RECENT = new java.util.LinkedHashMap<String, Long>() {
        @Override
        protected boolean removeEldestEntry(java.util.Map.Entry<String, Long> eldest) {
            return size() > 100;
        }
    };
    /** What Android shows other apps instead of a sensitive notification's text (Android 15+). */
    private static final String HIDDEN = "Sensitive notification content hidden";

    @Override
    public void onNotificationPosted(StatusBarNotification sbn) {
        String pkg = sbn.getPackageName();
        if (pkg.equals(getPackageName())) return;
        AppList.notified(this, pkg);
        Notification n = sbn.getNotification();
        if ((n.flags & (Notification.FLAG_ONGOING_EVENT | Notification.FLAG_GROUP_SUMMARY)) != 0) return;
        // Apps re-post old notifications after a restart (Messages does); those are not new events.
        if (n.when > 0 && System.currentTimeMillis() - n.when > STALE_MS) return;
        Bundle extras = n.extras;
        String title = text(extras.getCharSequence(Notification.EXTRA_TITLE));
        CharSequence big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT);
        String body = text(big != null ? big : extras.getCharSequence(Notification.EXTRA_TEXT));
        if (title.isEmpty() && body.isEmpty()) return;
        boolean hidden = body.equals(HIDDEN) || (title.isEmpty() && body.contains("content hidden"));
        // Hidden ones all read the same, so only bursts (re-posts within a moment) count as repeats.
        long window = hidden ? HIDDEN_REPEAT_MS : REPEAT_MS;
        String key = pkg + "|" + title + "|" + body;
        long now = System.currentTimeMillis();
        synchronized (RECENT) {
            Long seen = RECENT.get(key);
            RECENT.put(key, now);
            if (seen != null && now - seen < window) return;
        }
        try {
            Events.write(this, new JSONObject()
                .put("type", "notification")
                .put("app", appName(pkg))
                .put("package", pkg)
                .put("title", title)
                .put("text", body)
                .put("hidden", hidden));
        } catch (JSONException ignored) {
            // Strings always fit in JSON.
        }
    }

    private String appName(String pkg) {
        try {
            PackageManager pm = getPackageManager();
            ApplicationInfo info = pm.getApplicationInfo(pkg, 0);
            return pm.getApplicationLabel(info).toString();
        } catch (PackageManager.NameNotFoundException e) {
            return pkg;
        }
    }

    private static String text(CharSequence s) {
        return s == null ? "" : s.toString();
    }
}
