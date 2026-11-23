package dev.flowdroid.phone_bridge;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * "Ask Me": a notification with answer buttons and, optionally, a reply box.
 * The answer is written to app_flutter/answers/<id>.json, where the waiting
 * workflow (in the app or the background service) reads it.
 */
final class AskActions {
    private static final String CHANNEL = "workflow_questions";
    static final String ACTION_ANSWER = "dev.flowdroid.ASK_ANSWER";
    static final String EXTRA_ID = "id";
    static final String EXTRA_BUTTON = "button";
    static final String EXTRA_DISMISSED = "dismissed";
    static final String REPLY_KEY = "reply";

    private AskActions() {}

    static File answers(Context context) {
        return new File(context.getDir("flutter", Context.MODE_PRIVATE), "answers");
    }

    /** Posts the question; null when shown, else why not. */
    static String ask(Context context, String id, String title, String question, List<String> buttons, boolean reply) {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm == null || !nm.areNotificationsEnabled()) {
            return "notifications are off for FlowDroid, so it cannot ask: turn them on in Android settings";
        }
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(
                CHANNEL, "Questions from workflows", NotificationManager.IMPORTANCE_HIGH));
        }
        int notificationId = id.hashCode();
        int icon = context.getResources().getIdentifier("ic_stat_flow", "drawable", context.getPackageName());
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
            ? new Notification.Builder(context, CHANNEL)
            : new Notification.Builder(context);
        b.setSmallIcon(icon != 0 ? icon : context.getApplicationInfo().icon)
            .setContentTitle(title.isEmpty() ? "FlowDroid asks" : title)
            .setContentText(question)
            .setStyle(new Notification.BigTextStyle().bigText(question))
            .setCategory(Notification.CATEGORY_REMINDER)
            .setDeleteIntent(answerIntent(context, id, notificationId, 99, null, true, false));
        if (Build.VERSION.SDK_INT < 26) b.setPriority(Notification.PRIORITY_HIGH);
        int request = 0;
        if (reply) {
            RemoteInput input = new RemoteInput.Builder(REPLY_KEY).setLabel("Your answer").build();
            Notification.Action action = new Notification.Action.Builder(
                Icon.createWithResource(context, icon != 0 ? icon : context.getApplicationInfo().icon),
                "Reply",
                answerIntent(context, id, notificationId, request++, "", false, true))
                .addRemoteInput(input)
                .build();
            b.addAction(action);
        }
        for (String button : buttons) {
            b.addAction(new Notification.Action.Builder(
                Icon.createWithResource(context, icon != 0 ? icon : context.getApplicationInfo().icon),
                button,
                answerIntent(context, id, notificationId, request++, button, false, false)).build());
        }
        nm.notify(notificationId, b.build());
        return null;
    }

    private static PendingIntent answerIntent(
            Context context, String id, int notificationId, int request, String button, boolean dismissed, boolean mutable) {
        Intent intent = new Intent(context, AskReceiver.class)
            .setAction(ACTION_ANSWER + "." + id + "." + request)
            .putExtra(EXTRA_ID, id)
            .putExtra("notificationId", notificationId)
            .putExtra(EXTRA_DISMISSED, dismissed);
        if (button != null) intent.putExtra(EXTRA_BUTTON, button);
        // A reply box needs a mutable intent so Android can add the typed text.
        int flags = PendingIntent.FLAG_UPDATE_CURRENT
            | (mutable && Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : PendingIntent.FLAG_IMMUTABLE);
        return PendingIntent.getBroadcast(context, (id + request).hashCode(), intent, flags);
    }

    /** Takes the question away once it is answered elsewhere or the workflow stopped waiting. */
    static void cancel(Context context, String id) {
        NotificationManager nm = context.getSystemService(NotificationManager.class);
        if (nm != null) nm.cancel(id.hashCode());
    }

    /** Receives a tapped button, a typed reply, or the notification being swiped away. */
    public static class AskReceiver extends BroadcastReceiver {
        @Override
        public void onReceive(Context context, Intent intent) {
            String id = intent.getStringExtra(EXTRA_ID);
            if (id == null || !id.matches("[A-Za-z0-9_-]+")) return;
            try {
                JSONObject answer = new JSONObject();
                answer.put("button", intent.getStringExtra(EXTRA_BUTTON) == null ? "" : intent.getStringExtra(EXTRA_BUTTON));
                Bundle typed = RemoteInput.getResultsFromIntent(intent);
                CharSequence text = typed == null ? null : typed.getCharSequence(REPLY_KEY);
                answer.put("text", text == null ? "" : text.toString());
                answer.put("dismissed", intent.getBooleanExtra(EXTRA_DISMISSED, false));
                File dir = answers(context);
                if (!dir.isDirectory() && !dir.mkdirs()) return;
                File temp = new File(dir, id + ".tmp");
                try (FileOutputStream out = new FileOutputStream(temp)) {
                    out.write(answer.toString().getBytes(StandardCharsets.UTF_8));
                }
                if (!temp.renameTo(new File(dir, id + ".json"))) temp.delete();
            } catch (Exception e) {
                Log.w("FlowDroidAsk", "could not save the answer", e);
            }
            NotificationManager nm = context.getSystemService(NotificationManager.class);
            if (nm != null) nm.cancel(intent.getIntExtra("notificationId", id.hashCode()));
        }
    }
}
