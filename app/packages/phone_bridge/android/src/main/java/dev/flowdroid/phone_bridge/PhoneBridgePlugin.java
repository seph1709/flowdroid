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
import java.util.concurrent.Callable;
import java.util.concurrent.atomic.AtomicBoolean;

import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions;
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning;
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * FlowDroid's Android glue: sending SMS, phone-event receivers, the share sheet,
 * launcher shortcuts, notification access, opening or saving documents, and the
 * phone productivity steps (calendar, contacts, Ask Me, speech, sound mode,
 * alarms and timers, photos and document scans).
 */
public class PhoneBridgePlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.NewIntentListener, PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    static final String ACTION_RUN_WORKFLOW = "dev.flowdroid.RUN_WORKFLOW";
    private static final int REQUEST_OPEN = 7101;
    private static final int REQUEST_SAVE = 7102;
    private static final int REQUEST_SMS = 7103;
    private static final int REQUEST_CONTACT = 7104;
    private static final int REQUEST_PERMISSIONS = 7105;
    private static final int REQUEST_SPEECH = 7106;
    private static final int REQUEST_CAMERA = 7107;
    private static final int REQUEST_GALLERY = 7108;
    private static final int REQUEST_SCAN = 7109;
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
    private MethodChannel.Result pendingPermissions;
    private MethodChannel.Result pendingSpeech;
    private MethodChannel.Result pendingPhoto;
    private File cameraFile;

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
        // An unexpected failure in one action must not take the whole app (and its workflows) down.
        try {
            handle(call, result);
        } catch (Throwable t) {
            try {
                result.error("failed", call.method + " failed: " + t, null);
            } catch (Throwable ignored) {
                // Already answered.
            }
        }
    }

    private void handle(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "status":
                Map<String, Object> status = new HashMap<>();
                status.put("sms", granted(Manifest.permission.RECEIVE_SMS) && granted(Manifest.permission.SEND_SMS));
                status.put("notificationAccess", notificationAccess());
                status.put("calendar", granted(Manifest.permission.READ_CALENDAR) && granted(Manifest.permission.WRITE_CALENDAR));
                status.put("contacts", granted(Manifest.permission.READ_CONTACTS) && granted(Manifest.permission.WRITE_CONTACTS));
                status.put("microphone", granted(Manifest.permission.RECORD_AUDIO));
                status.put("dnd", SoundActions.dndAccess(context));
                result.success(status);
                break;
            case "ensurePermissions":
                ensurePermissions(call.argument("names"), result);
                break;
            case "openDndAccess":
                SoundActions.openDndAccess(context);
                result.success(null);
                break;
            case "calendarEvents": {
                Number from = call.argument("from");
                Number to = call.argument("to");
                String calendar = call.argument("calendar");
                background(result, () -> CalendarActions.events(
                    context, from == null ? 0 : from.longValue(), to == null ? 0 : to.longValue(), calendar));
                break;
            }
            case "calendarCreate": {
                Map<String, Object> event = call.argument("event");
                background(result, () -> CalendarActions.create(context, event));
                break;
            }
            case "contactsFind": {
                String query = call.argument("query");
                Number limit = call.argument("limit");
                background(result, () -> ContactActions.find(context, query, limit == null ? 5 : limit.intValue()));
                break;
            }
            case "contactsAdd": {
                String name = call.argument("name");
                String phone = call.argument("phone");
                String email = call.argument("email");
                background(result, () -> ContactActions.add(context, name, phone, email));
                break;
            }
            case "ask": {
                List<String> buttons = call.argument("buttons");
                Boolean reply = call.argument("reply");
                String problem = AskActions.ask(context, call.argument("id"), call.argument("title"), call.argument("question"),
                    buttons == null ? new ArrayList<>() : buttons, Boolean.TRUE.equals(reply));
                result.success(problem == null ? new HashMap<String, Object>() : error(problem));
                break;
            }
            case "askCancel":
                AskActions.cancel(context, call.argument("id"));
                result.success(null);
                break;
            case "listen": {
                Number maxMs = call.argument("maxMs");
                listen(call.argument("language"), call.argument("prompt"), maxMs == null ? 30000 : maxMs.longValue(), result);
                break;
            }
            case "soundMode":
                result.success(SoundActions.set(context, call.argument("mode")));
                break;
            case "clock": {
                String operation = call.argument("operation");
                Number hour = call.argument("hour");
                Number minute = call.argument("minute");
                Number seconds = call.argument("seconds");
                List<String> days = call.argument("days");
                String label = call.argument("label");
                if ("alarm".equals(operation)) {
                    result.success(ClockActions.alarm(context, hour == null ? 0 : hour.intValue(),
                        minute == null ? 0 : minute.intValue(), days, label));
                } else if ("timer".equals(operation)) {
                    result.success(ClockActions.timer(context, seconds == null ? 60 : seconds.intValue(), label));
                } else {
                    result.success(ClockActions.showAlarms(context));
                }
                break;
            }
            case "browserOpen": {
                Number timeout = call.argument("timeoutMs");
                Boolean fast = call.argument("fast");
                // A window left open by the last run shows this page too: it is busy again.
                BrowserActivity.status(call.argument("session"), true);
                Browser.open(context, call.argument("session"), call.argument("url"), Boolean.TRUE.equals(fast),
                    timeout == null ? 30000 : timeout.longValue(), once(result));
                break;
            }
            case "browserEval":
                Browser.eval(call.argument("session"), call.argument("js"), once(result));
                break;
            case "browserBack":
                result.success(Browser.back(call.argument("session")));
                break;
            case "browserScreenshot":
                result.success(Browser.screenshot(call.argument("session"),
                    new File(PhotoActions.filesDir(context), (String) call.argument("path"))));
                break;
            case "browserShow":
                result.success(showBrowser(call.argument("session"), false));
                break;
            case "browserHide":
                BrowserActivity.closeFor(call.argument("session"));
                result.success(null);
                break;
            case "browserFinished":
                BrowserActivity.status(call.argument("session"), false);
                result.success(null);
                break;
            case "browserClose":
                Browser.close(call.argument("session"));
                result.success(null);
                break;
            case "browserLogin": {
                String session = "login";
                // A login screen already open is replaced: answer its caller now, or it waits forever.
                java.util.function.Consumer<String> previous = BrowserActivity.takeDone(session);
                Browser.close(session);
                if (previous != null) previous.accept("");
                try {
                    // A workflow or the assistant may have the site open: one tab at a time.
                    Browser.releaseSite(session, call.argument("url"));
                    Browser.session(context, session, false).web.loadUrl(call.argument("url"));
                } catch (RuntimeException e) {
                    result.success(Browser.error(e.getMessage()));
                    break;
                }
                Map<String, Object> shown = showBrowser(session, true);
                if (shown.containsKey("error")) {
                    Browser.close(session);
                    result.success(shown);
                    break;
                }
                BrowserActivity.onDone(session, url -> {
                    Browser.close(session);
                    Map<String, Object> out = new HashMap<>();
                    out.put("url", url);
                    result.success(out);
                });
                break;
            }
            case "browserCookies":
                result.success(Browser.cookies(call.argument("url")));
                break;
            case "browserForget":
                Browser.forget(call.argument("url"));
                result.success(null);
                break;
            case "browserClearLogins":
                Browser.clearLogins();
                result.success(null);
                break;
            case "photo": {
                Boolean multiple = call.argument("multiple");
                Number pages = call.argument("pages");
                Boolean pdf = call.argument("pdf");
                photo(call.argument("source"), Boolean.TRUE.equals(multiple), pages == null ? 5 : pages.intValue(),
                    Boolean.TRUE.equals(pdf), result);
                break;
            }
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

    /** Runs [work] off the main thread; its value, or `{error}` with what went wrong. */
    private static void background(MethodChannel.Result result, Callable<Object> work) {
        Handler main = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            Object answer;
            try {
                answer = work.call();
            } catch (SecurityException e) {
                answer = error("FlowDroid may not do this yet: allow it in Settings → Phone access");
            } catch (Exception e) {
                answer = error(e.getMessage() == null ? e.toString() : e.getMessage());
            }
            Object reply = answer;
            main.post(() -> result.success(reply));
        }).start();
    }

    // ---------- Permissions ----------

    private static String[] permissionsFor(String name) {
        switch (name) {
            case "calendar": return new String[] {Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR};
            case "contacts": return new String[] {Manifest.permission.READ_CONTACTS, Manifest.permission.WRITE_CONTACTS};
            case "microphone": return new String[] {Manifest.permission.RECORD_AUDIO};
            default: return new String[0];
        }
    }

    /** True when FlowDroid has every permission [names] stand for, asking for the missing ones when it can. */
    private void ensurePermissions(List<String> names, MethodChannel.Result result) {
        List<String> missing = new ArrayList<>();
        for (String name : names == null ? new ArrayList<String>() : names) {
            for (String p : permissionsFor(name)) if (!granted(p)) missing.add(p);
        }
        if (missing.isEmpty()) {
            result.success(true);
            return;
        }
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null) {
            // No screen to ask on (the background service): the step reports what to allow.
            result.success(false);
            return;
        }
        if (pendingPermissions != null) pendingPermissions.success(false);
        pendingPermissions = result;
        activity.requestPermissions(missing.toArray(new String[0]), REQUEST_PERMISSIONS);
    }

    @Override
    public boolean onRequestPermissionsResult(int request, @NonNull String[] permissions, @NonNull int[] results) {
        if (request != REQUEST_PERMISSIONS) return false;
        MethodChannel.Result result = pendingPermissions;
        pendingPermissions = null;
        boolean all = results.length > 0;
        for (int r : results) all &= r == PackageManager.PERMISSION_GRANTED;
        if (result != null) result.success(all);
        return true;
    }

    // ---------- Speech ----------

    /** Android's speech dialog while FlowDroid is on screen; otherwise the recognizer listens without one. */
    private void listen(String language, String prompt, long maxMs, MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity != null && DeviceActions.onScreen()) {
            try {
                if (pendingSpeech != null) pendingSpeech.success(error("listening again"));
                pendingSpeech = result;
                activity.startActivityForResult(SpeechActions.recognizeIntent(language, prompt), REQUEST_SPEECH);
                return;
            } catch (RuntimeException e) {
                pendingSpeech = null;
                // No speech dialog on this phone: listen without one.
            }
        }
        SpeechActions.listen(context, language, maxMs, result::success);
    }

    // ---------- Photos and scans ----------

    private void photo(String source, boolean multiple, int pages, boolean pdf, MethodChannel.Result result) {
        Activity activity = binding == null ? null : binding.getActivity();
        if (activity == null || !DeviceActions.onScreen()) {
            result.success(error("photos and scans need FlowDroid on screen: run this step from the app, a home-screen shortcut or the share sheet"));
            return;
        }
        if (pendingPhoto != null) pendingPhoto.success(cancelled());
        pendingPhoto = result;
        try {
            switch (String.valueOf(source)) {
                case "gallery":
                    activity.startActivityForResult(PhotoActions.galleryIntent(multiple), REQUEST_GALLERY);
                    break;
                case "scan": {
                    GmsDocumentScannerOptions.Builder options = new GmsDocumentScannerOptions.Builder()
                        .setGalleryImportAllowed(true)
                        .setPageLimit(Math.max(1, Math.min(20, pages)))
                        .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL);
                    if (pdf) {
                        options.setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG, GmsDocumentScannerOptions.RESULT_FORMAT_PDF);
                    } else {
                        options.setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG);
                    }
                    GmsDocumentScanning.getClient(options.build()).getStartScanIntent(activity)
                        .addOnSuccessListener(sender -> {
                            try {
                                activity.startIntentSenderForResult(sender, REQUEST_SCAN, null, 0, 0, 0);
                            } catch (Exception e) {
                                finishPhoto(error("could not start the document scanner: " + e.getMessage()));
                            }
                        })
                        .addOnFailureListener(e -> finishPhoto(error(
                            "the document scanner needs Google Play services: " + e.getMessage())));
                    break;
                }
                default:
                    cameraFile = PhotoActions.cameraTarget(context);
                    activity.startActivityForResult(PhotoActions.cameraIntent(context, cameraFile), REQUEST_CAMERA);
            }
        } catch (android.content.ActivityNotFoundException e) {
            finishPhoto(error("no app on this phone can do this"));
        } catch (Exception e) {
            finishPhoto(error("could not start: " + e.getMessage()));
        }
    }

    private void finishPhoto(Object answer) {
        MethodChannel.Result result = pendingPhoto;
        pendingPhoto = null;
        if (result != null) result.success(answer);
    }

    private static Map<String, Object> cancelled() {
        Map<String, Object> out = new HashMap<>();
        out.put("files", new ArrayList<String>());
        out.put("cancelled", true);
        return out;
    }

    /** Copies what the camera, picker or scanner returned into FlowDroid's folder, off the main thread. */
    private void photoResult(int request, int code, Intent data) {
        if (code != Activity.RESULT_OK) {
            finishPhoto(cancelled());
            return;
        }
        File camera = cameraFile;
        cameraFile = null;
        Handler main = new Handler(Looper.getMainLooper());
        new Thread(() -> {
            Map<String, Object> out = new HashMap<>();
            List<String> files = new ArrayList<>();
            try {
                if (request == REQUEST_CAMERA) {
                    files.add(PhotoActions.keepCameraPhoto(context, camera));
                } else if (request == REQUEST_GALLERY) {
                    if (data != null && data.getClipData() != null) {
                        for (int i = 0; i < data.getClipData().getItemCount(); i++) {
                            files.add(PhotoActions.copyIn(context, data.getClipData().getItemAt(i).getUri(), "photos", "photo.jpg"));
                        }
                    } else if (data != null && data.getData() != null) {
                        files.add(PhotoActions.copyIn(context, data.getData(), "photos", "photo.jpg"));
                    }
                } else {
                    GmsDocumentScanningResult scan = GmsDocumentScanningResult.fromActivityResultIntent(data);
                    if (scan != null && scan.getPages() != null) {
                        int n = 1;
                        for (GmsDocumentScanningResult.Page page : scan.getPages()) {
                            files.add(PhotoActions.copyIn(context, page.getImageUri(), "scans", "page-" + n++ + ".jpg"));
                        }
                    }
                    if (scan != null && scan.getPdf() != null) {
                        out.put("pdf", PhotoActions.copyIn(context, scan.getPdf().getUri(), "scans", "scan.pdf"));
                    }
                }
                out.put("files", files);
            } catch (Exception e) {
                out.clear();
                out.put("error", "could not keep the photo: " + e.getMessage());
            }
            main.post(() -> finishPhoto(out));
        }).start();
    }

    /** A reply that is sent at most once, however often the browser calls back. */
    private static <T> java.util.function.Consumer<T> once(MethodChannel.Result result) {
        java.util.concurrent.atomic.AtomicBoolean sent = new java.util.concurrent.atomic.AtomicBoolean();
        return value -> {
            if (sent.compareAndSet(false, true)) result.success(value);
        };
    }

    /** Puts a browser session on screen; needs FlowDroid on screen to start from. */
    private Map<String, Object> showBrowser(String session, boolean login) {
        if (Browser.get(session) == null) return Browser.error("no page is open");
        if (!DeviceActions.onScreen() && !Settings.canDrawOverlays(context)) {
            return Browser.error("showing the browser needs FlowDroid on screen");
        }
        if (!login && BrowserActivity.isShowing(session)) {
            // Already on screen (left up by the last run): reuse it, no new window sliding in.
            // One left behind other apps is replaced below, so the run is seen.
            BrowserActivity.status(session, true);
            return new HashMap<>();
        }
        BrowserActivity.opening(session);
        context.startActivity(new Intent(context, BrowserActivity.class)
            .putExtra(BrowserActivity.EXTRA_SESSION, session)
            .putExtra(BrowserActivity.EXTRA_LOGIN, login)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        return new HashMap<>();
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
        if (request == REQUEST_SPEECH) {
            MethodChannel.Result result = pendingSpeech;
            pendingSpeech = null;
            if (result == null) return true;
            if (code != Activity.RESULT_OK || data == null) {
                Map<String, Object> none = SpeechActions.resultOf(null, null);
                none.put("cancelled", true);
                result.success(none);
            } else {
                result.success(SpeechActions.resultOf(
                    data.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS),
                    data.getFloatArrayExtra(android.speech.RecognizerIntent.EXTRA_CONFIDENCE_SCORES)));
            }
            return true;
        }
        if (request == REQUEST_CAMERA || request == REQUEST_GALLERY || request == REQUEST_SCAN) {
            photoResult(request, code, data);
            return true;
        }
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
        binding.addRequestPermissionsResultListener(this);
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
            binding.removeRequestPermissionsResultListener(this);
        }
        binding = null;
    }
}
