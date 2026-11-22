package dev.flowdroid.phone_bridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import org.json.JSONException;
import org.json.JSONObject;

/** Records that the phone started, for the Phone Event Trigger's "boot" event. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        try {
            Events.write(context, new JSONObject().put("type", "phone").put("event", "boot"));
        } catch (JSONException ignored) {
            // Constant strings always fit in JSON.
        }
    }
}
