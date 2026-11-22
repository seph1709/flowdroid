package dev.flowdroid.phone_bridge;

import android.content.Context;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Hands phone events to the Dart side as small JSON files in app_flutter/events.
 * Whichever FlowDroid engine is running (app or background service) picks them up,
 * so nothing is lost while the process starts.
 */
final class Events {
    private static final String TAG = "FlowDroidEvents";
    private static final AtomicLong SEQUENCE = new AtomicLong();
    /** The Dart side touches this file every few seconds while it is processing events. */
    private static final long ALIVE_MS = 15_000;

    private Events() {}

    static File dir(Context context) {
        // path_provider's getApplicationDocumentsDirectory() on Android.
        return new File(context.getDir("flutter", Context.MODE_PRIVATE), "events");
    }

    static void write(Context context, JSONObject event) {
        try {
            File dir = dir(context);
            if (!dir.isDirectory() && !dir.mkdirs()) return;
            event.put("at", System.currentTimeMillis());
            String name = System.currentTimeMillis() + "-" + SEQUENCE.incrementAndGet();
            File temp = new File(dir, name + ".tmp");
            try (FileOutputStream out = new FileOutputStream(temp)) {
                out.write(event.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!temp.renameTo(new File(dir, name + ".json"))) temp.delete();
        } catch (Exception e) {
            Log.w(TAG, "could not save a phone event", e);
        }
        // Nobody may be running to pick the event up (Android or the phone's battery
        // manager stopped FlowDroid): start the background service so it runs now,
        // not whenever the app is next opened.
        Wake.ensureRunning(context);
    }

    /** Whether a FlowDroid engine processed events in the last few seconds. */
    static boolean dartAlive(Context context) {
        File alive = new File(dir(context), ".alive");
        return alive.exists() && System.currentTimeMillis() - alive.lastModified() < ALIVE_MS;
    }
}
