package dev.flowdroid.phone_bridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/** Saves each incoming SMS (joined from its parts) as an event for the SMS Trigger. */
public class SmsReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) return;
        SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null) return;
        Map<String, StringBuilder> bySender = new LinkedHashMap<>();
        for (SmsMessage part : parts) {
            String from = part.getDisplayOriginatingAddress();
            bySender.computeIfAbsent(from == null ? "" : from, k -> new StringBuilder()).append(part.getMessageBody());
        }
        for (Map.Entry<String, StringBuilder> message : bySender.entrySet()) {
            try {
                Events.write(context, new JSONObject()
                    .put("type", "sms")
                    .put("from", message.getKey())
                    .put("text", message.getValue().toString()));
            } catch (JSONException ignored) {
                // Strings always fit in JSON.
            }
        }
    }
}
