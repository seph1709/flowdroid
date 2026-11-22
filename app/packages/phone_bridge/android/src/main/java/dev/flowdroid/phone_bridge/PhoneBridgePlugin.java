package dev.flowdroid.phone_bridge;

import android.Manifest;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.database.Cursor;
import android.graphics.drawable.Icon;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.telephony.SmsManager;

import androidx.annotation.NonNull;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * FlowDroid's Android glue: sending SMS, phone-event receivers, the share sheet,
 * launcher shortcuts, notification access, and opening or saving documents.
 */
public class PhoneBridgePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.NewIntentListener, PluginRegistry.ActivityResultListener {

    static final String ACTION_RUN_WORKFLOW = "dev.flowdroid.RUN_WORKFLOW";
    private static final int REQUEST_OPEN = 7101;
    private static final int REQUEST_SAVE = 7102;
    private static final int REQUEST_SMS = 7103;
    private static final int REQUEST_CONTACT = 7104;
    private static final AtomicBoolean WATCHING = new AtomicBoolean(false);

    private Context context;
    private MethodChannel channel;
    private ActivityPluginBinding binding;
    /** What the app was opened for (shared content or a shortcut), until Dart takes it. */
    private Map<String, Object> pendingLaunch;
    private MethodChannel.Result pendingDocument;
    private MethodChannel.Result pendingContact;
    private String pendingContactKind;
    private byte[] bytesToSave;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutter) {
        context = flutter.getApplicationContext();
        channel = new MethodChannel(flutter.getBinaryMessenger(), "flowdroid/phone");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding flutter) {
        channel.setMethodCallHandler(null);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "status":
                Map<String, Object> status = new HashMap<>();
                status.put("sms", granted(Manifest.permission.RECEIVE_SMS) && granted(Manifest.permission.SEND_SMS));
                status.put("notificationAccess", notificationAccess());
                result.success(status);
                break;
            case "requestSms":
                Activity activity = binding == null ? null : binding.getActivity();
                if (activity != null) {
                    activity.requestPermissions(
                        new String[] {Manifest.permission.RECEIVE_SMS, Manifest.permission.SEND_SMS}, REQUEST_SMS);
                }
                result.success(null);
                break;
            case "openNotificationAccess":
                Intent settings = new Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS);
                settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(settings);
                result.success(null);
                break;
            case "sendSms":
                sendSms(call.argument("to"), call.argument("text"), result);
                break;
            case "watchPhoneEvents":
                watchPhoneEvents();
                result.success(null);
                break;
            case "takeLaunch":
                result.success(pendingLaunch);
                pendingLaunch = null;
                break;
            case "pinShortcut":
                result.success(pinShortcut(call.argument("workflowId"), call.argument("label")));
                break;
            case "openDocument":
                startDocument(new Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*"), REQUEST_OPEN, null, result);
                break;
            case "saveDocument":
                startDocument(new Intent(Intent.ACTION_CREATE_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(call.argument("mime"))
                    .putExtra(Intent.EXTRA_TITLE, (String) call.argument("name")), REQUEST_SAVE, call.argument("bytes"), result);
                break;
            case "installedApps": {
                Handler main = new Handler(Looper.getMainLooper());
                new Thread(() -> {
                    List<Map<String, Object>> apps = AppList.installed(context);
                    main.post(() -> result.success(apps));
                }).start();
                break;
            }
            case "vibrate": {
                Number ms = call.argument("ms");
                result.success(DeviceActions.vibrate(context, ms == null ? 500 : ms.longValue()));
                break;
            }
            case "openUrl":
                result.success(DeviceActions.openUrl(context, call.argument("url")));
                break;
            case "clipboardWrite":
                DeviceActions.clipboardWrite(context, call.argument("text"));
                result.success(null);
                break;
            case "clipboardRead":
                result.success(DeviceActions.clipboardRead(context));
                break;
            case "openFile":
                result.success(FileActions.open(context, call.argument("path"), call.argument("mime")));
                break;
            case "shareFile":
                result.success(FileActions.share(context, call.argument("path"), call.argument("mime")));
                break;
            case "playAudio":
                AudioPlayer.play(call.argument("source"), result);
                break;
            case "stopAudio":
                AudioPlayer.stop();
                result.success(null);
                break;
            case "pickContact":
                pickContact(call.argument("kind"), result);
                break;
            case "backgroundStatus":
                result.success(BackgroundSettings.status(context));
                break;
            case "openBackgroundSettings":
                result.success(BackgroundSettings.open(context, call.argument("kind")));
                break;
            case "setWakeAlarm": {
                Number at = call.argument("at");
                result.success(Wake.setAlarm(context, at == null ? 0 : at.longValue()));
                break;
            }
            case "wakeService":
                Wake.restartService(context);
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private boolean granted(String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    private boolean notificationAccess() {
        String enabled = Settings.Secure.getString(context.getContentResolver(), "enabled_notification_listeners");
        ComponentName me = new ComponentName(context, NotificationWatcher.class);
        return enabled != null && enabled.contains(me.flattenToString());
    }

    private void sendSms(String to, String text, MethodChannel.Result result) {
        if (!granted(Manifest.permission.SEND_SMS)) {
            result.success(error("FlowDroid may not send SMS yet: allow it in Settings → Phone access"));
            return;
        }
        try {
            SmsManager sms = Build.VERSION.SDK_INT >= 31
                ? context.getSystemService(SmsManager.class)
                : SmsManager.getDefault();
            ArrayList<String> parts = sms.divideMessage(text == null ? "" : text);
            sms.sendMultipartTextMessage(to, null, parts, null, null);
            result.success(new HashMap<String, Object>());
        } catch (RuntimeException e) {
            result.success(error("could not send the SMS: " + e.getMessage()));
        }
    }

    /** Power, screen, battery and Wi-Fi changes become events while this process lives. */
    private void watchPhoneEvents() {
        if (!WATCHING.compareAndSet(false, true)) return;
        Context app = context.getApplicationContext();
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                String event;
                switch (String.valueOf(intent.getAction())) {
                    case Intent.ACTION_POWER_CONNECTED: event = "powerConnected"; break;
                    case Intent.ACTION_POWER_DISCONNECTED: event = "powerDisconnected"; break;
                    case Intent.ACTION_BATTERY_LOW: event = "batteryLow"; break;
                    case Intent.ACTION_SCREEN_ON: event = "screenOn"; break;
                    case Intent.ACTION_SCREEN_OFF: event = "screenOff"; break;
                    default: return;
                }
                phoneEvent(c, event);
            }
        };
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_POWER_CONNECTED);
        filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
        filter.addAction(Intent.ACTION_BATTERY_LOW);
        filter.addAction(Intent.ACTION_SCREEN_ON);
        filter.addAction(Intent.ACTION_SCREEN_OFF);
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            app.registerReceiver(receiver, filter);
        }

        ConnectivityManager cm = app.getSystemService(ConnectivityManager.class);
        if (cm == null) return;
        long since = System.currentTimeMillis();
        NetworkRequest wifi = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build();
        cm.registerNetworkCallback(wifi, new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(@NonNull Network network) {
                // Registering reports the current connection at once; that is not a change.
                if (System.currentTimeMillis() - since > 2000) phoneEvent(app, "wifiConnected");
            }

            @Override
            public void onLost(@NonNull Network network) {
                phoneEvent(app, "wifiDisconnected");
            }
        });
    }

    private static void phoneEvent(Context context, String event) {
        try {
            Events.write(context, new JSONObject().put("type", "phone").put("event", event));
        } catch (JSONException ignored) {
            // Constant strings always fit in JSON.
        }
    }

    private boolean pinShortcut(String workflowId, String label) {
        if (Build.VERSION.SDK_INT < 26 || workflowId == null) return false;
        ShortcutManager manager = context.getSystemService(ShortcutManager.class);
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (manager == null || !manager.isRequestPinShortcutSupported() || launch == null || launch.getComponent() == null) {
            return false;
        }
        Intent run = new Intent(ACTION_RUN_WORKFLOW)
            .setComponent(launch.getComponent())
            .putExtra("workflowId", workflowId)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        ShortcutInfo info = new ShortcutInfo.Builder(context, "workflow-" + workflowId)
            .setShortLabel(label == null || label.isEmpty() ? "Workflow" : label)
            .setIcon(Icon.createWithResource(context, context.getApplicationInfo().icon))
            .setIntent(run)
            .build();
        return manager.requestPinShortcut(info, null);
    }

    // ---------- What the app was opened with ----------

    private void takeIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        Map<String, Object> launch = null;
        if (ACTION_RUN_WORKFLOW.equals(action)) {
            launch = new HashMap<>();
            launch.put("type", "workflow");
            launch.put("workflowId", intent.getStringExtra("workflowId"));
        } else if (Intent.ACTION_SEND.equals(action) || Intent.ACTION_SEND_MULTIPLE.equals(action)) {
            launch = new HashMap<>();
            launch.put("type", "share");
            launch.put("text", intent.getStringExtra(Intent.EXTRA_TEXT));
            launch.put("subject", intent.getStringExtra(Intent.EXTRA_SUBJECT));
            launch.put("files", copySharedFiles(intent));
        }
        if (launch == null) return;
        // Handle each intent once, even when the activity is recreated.
        intent.setAction(null);
        pendingLaunch = launch;
        channel.invokeMethod("launch", null);
    }

    /** Copies shared files into FlowDroid's folder (files/shared), where workflows and Ubuntu can read them. */
    @SuppressWarnings("deprecation")
    private List<String> copySharedFiles(Intent intent) {
        List<Uri> uris = new ArrayList<>();
        if (Intent.ACTION_SEND.equals(intent.getAction())) {
            Uri one = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (one != null) uris.add(one);
        } else {
            ArrayList<Uri> many = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
            if (many != null) uris.addAll(many);
        }
        List<String> paths = new ArrayList<>();
        File dir = new File(new File(context.getDir("flutter", Context.MODE_PRIVATE), "files"), "shared");
        if (!dir.isDirectory() && !dir.mkdirs()) return paths;
        for (Uri uri : uris) {
            String name = displayName(uri);
            File target = new File(dir, System.currentTimeMillis() + "-" + name);
            try (InputStream in = context.getContentResolver().openInputStream(uri);
                 OutputStream out = new FileOutputStream(target)) {
                if (in == null) continue;
                byte[] buffer = new byte[64 * 1024];
                for (int n = in.read(buffer); n > 0; n = in.read(buffer)) out.write(buffer, 0, n);
                paths.add("shared/" + target.getName());
            } catch (Exception ignored) {
                // A file that cannot be read is skipped; the text still arrives.
            }
        }
        return paths;
    }

    private String displayName(Uri uri) {
        String name = "file";
        try (Cursor c = context.getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) name = c.getString(0);
        } catch (RuntimeException ignored) {
            // Keep the generic name.
        }
        return name.replaceAll("[^A-Za-z0-9._-]", "_");
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        takeIntent(intent);
        return false;
    }

    // ---------- Opening and saving documents ----------

    private void startDocument(Intent intent, int request, byte[] bytes, MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            result.success(null);
            return;
        }
        if (pendingDocument != null) pendingDocument.success(null);
        pendingDocument = result;
        bytesToSave = bytes;
        activity.startActivityForResult(intent, request);
    }

    /** Android's own contact chooser: it grants access to the one picked contact, so no permission is needed. */
    private void pickContact(String kind, MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            result.success(null);
            return;
        }
        if (pendingContact != null) pendingContact.success(null);
        pendingContact = result;
        pendingContactKind = kind;
        Uri type = "email".equals(kind)
            ? android.provider.ContactsContract.CommonDataKinds.Email.CONTENT_URI
            : android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI;
        try {
            activity.startActivityForResult(new Intent(Intent.ACTION_PICK, type), REQUEST_CONTACT);
        } catch (RuntimeException e) {
            pendingContact = null;
            result.success(null);
        }
    }

    private Map<String, Object> readContact(Uri uri, boolean email) {
        String column = email
            ? android.provider.ContactsContract.CommonDataKinds.Email.ADDRESS
            : android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER;
        String name = android.provider.ContactsContract.Contacts.DISPLAY_NAME;
        try (Cursor c = context.getContentResolver().query(uri, new String[] {column, name}, null, null, null)) {
            if (c == null || !c.moveToFirst()) return null;
            Map<String, Object> out = new HashMap<>();
            out.put("value", c.getString(0));
            out.put("name", c.getString(1));
            return out;
        } catch (RuntimeException e) {
            return null;
        }
    }

    @Override
    public boolean onActivityResult(int request, int code, Intent data) {
        if (request == REQUEST_CONTACT) {
            MethodChannel.Result result = pendingContact;
            pendingContact = null;
            Uri uri = code == Activity.RESULT_OK && data != null ? data.getData() : null;
            if (result != null) result.success(uri == null ? null : readContact(uri, "email".equals(pendingContactKind)));
            return true;
        }
        if (request != REQUEST_OPEN && request != REQUEST_SAVE) return false;
        MethodChannel.Result result = pendingDocument;
        pendingDocument = null;
        if (result == null) return true;
        Uri uri = code == Activity.RESULT_OK && data != null ? data.getData() : null;
        if (uri == null) {
            result.success(null);
            return true;
        }
        Handler main = new Handler(Looper.getMainLooper());
        byte[] toSave = bytesToSave;
        bytesToSave = null;
        new Thread(() -> {
            Object answer;
            try {
                if (request == REQUEST_OPEN) {
                    try (InputStream in = context.getContentResolver().openInputStream(uri)) {
                        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                        byte[] chunk = new byte[64 * 1024];
                        for (int n = in.read(chunk); n > 0; n = in.read(chunk)) buffer.write(chunk, 0, n);
                        answer = buffer.toByteArray();
                    }
                } else {
                    try (OutputStream out = context.getContentResolver().openOutputStream(uri)) {
                        out.write(toSave == null ? new byte[0] : toSave);
                    }
                    answer = true;
                }
            } catch (Exception e) {
                answer = null;
            }
            Object reply = answer;
            main.post(() -> result.success(reply));
        }).start();
        return true;
    }

    private static Map<String, Object> error(String message) {
        Map<String, Object> out = new HashMap<>();
        out.put("error", message);
        return out;
    }

    // ---------- Activity lifecycle ----------

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding activityBinding) {
        binding = activityBinding;
        binding.addOnNewIntentListener(this);
        binding.addActivityResultListener(this);
        takeIntent(binding.getActivity().getIntent());
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding activityBinding) {
        onAttachedToActivity(activityBinding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (binding != null) {
            binding.removeOnNewIntentListener(this);
            binding.removeActivityResultListener(this);
        }
        binding = null;
    }
}
