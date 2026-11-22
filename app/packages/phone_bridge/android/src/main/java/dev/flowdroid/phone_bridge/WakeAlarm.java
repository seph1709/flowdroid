package dev.flowdroid.phone_bridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * The wake-up alarm: a schedule is due (or the watchdog interval passed).
 * Queues a "tick" for whichever FlowDroid engine runs, restarting the
 * background service first when nothing is running.
 */
public class WakeAlarm extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            Events.write(context, new JSONObject().put("type", "tick"));
        } catch (JSONException ignored) {
            // Constant strings always fit in JSON.
        }
    }
}
