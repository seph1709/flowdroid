package dev.flowdroid.phone_bridge;

import android.app.ActivityManager;
import android.app.NotificationManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * What stands between FlowDroid and running in the background, and the system
 * screens where the user can change it, including phone makers' own
 * "auto-launch" managers (Huawei, Honor, Xiaomi, Oppo, Vivo, Samsung…).
 */
final class BackgroundSettings {
    private BackgroundSettings() {}

    /** Screens tried in order for each maker; the first one that opens wins. */
    private static final Map<String, String[]> AUTOSTART = new HashMap<>();

    static {
        String[] huawei = {
            "com.huawei.systemmanager/.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager/.appcontrol.activity.StartupAppControlActivity",
            "com.huawei.systemmanager/.optimize.process.ProtectActivity",
        };
        AUTOSTART.put("huawei", huawei);
        AUTOSTART.put("honor", new String[] {
            "com.hihonor.systemmanager/.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager/.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager/.appcontrol.activity.StartupAppControlActivity",
        });
        String[] xiaomi = {"com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity"};
        AUTOSTART.put("xiaomi", xiaomi);
        AUTOSTART.put("redmi", xiaomi);
        AUTOSTART.put("poco", xiaomi);
        String[] oppo = {
            "com.coloros.safecenter/.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter/.startupapp.StartupAppListActivity",
            "com.oppo.safe/.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter/com.coloros.privacypermissionsentry.PermissionTopActivity",
        };
        AUTOSTART.put("oppo", oppo);
        AUTOSTART.put("realme", oppo);
        AUTOSTART.put("oneplus", new String[] {
            "com.oneplus.security/.chainlaunch.view.ChainLaunchAppListActivity",
            "com.coloros.safecenter/.startupapp.StartupAppListActivity",
        });
        String[] vivo = {
            "com.vivo.permissionmanager/.activity.BgStartUpManagerActivity",
            "com.iqoo.secure/.ui.phoneoptimize.BgStartUpManager",
            "com.iqoo.secure/.ui.phoneoptimize.AddWhiteListActivity",
        };
        AUTOSTART.put("vivo", vivo);
        AUTOSTART.put("iqoo", vivo);
        AUTOSTART.put("samsung", new String[] {
            "com.samsung.android.lool/com.samsung.android.sm.battery.ui.BatteryActivity",
            "com.samsung.android.lool/com.samsung.android.sm.ui.battery.BatteryActivity",
        });
        AUTOSTART.put("asus", new String[] {
            "com.asus.mobilemanager/.autostart.AutoStartActivity",
            "com.asus.mobilemanager/.MainActivity",
        });
        String[] transsion = {"com.transsion.phonemaster/com.cyin.himgr.autostart.AutoStartActivity"};
        AUTOSTART.put("tecno", transsion);
        AUTOSTART.put("infinix", transsion);
        AUTOSTART.put("itel", transsion);
        AUTOSTART.put("meizu", new String[] {"com.meizu.safe/.permission.SmartBGActivity"});
        AUTOSTART.put("letv", new String[] {"com.letv.android.letvsafe/.AutostartManageActivity"});
    }

    static String maker() {
        String m = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.toLowerCase(Locale.ROOT);
        String b = Build.BRAND == null ? "" : Build.BRAND.toLowerCase(Locale.ROOT);
        // Honor phones made before the split still say "huawei" as maker.
        if (b.equals("honor")) return "honor";
        if (AUTOSTART.containsKey(m)) return m;
        return AUTOSTART.containsKey(b) ? b : m;
    }

    static Map<String, Object> status(Context context) {
        Map<String, Object> out = new HashMap<>();
        String maker = maker();
        out.put("maker", maker);
        out.put("brand", Build.BRAND);
        out.put("model", Build.MODEL);
        out.put("sdk", Build.VERSION.SDK_INT);
        out.put("hasAutostartScreen", AUTOSTART.containsKey(maker));
        PowerManager power = context.getSystemService(PowerManager.class);
        out.put("batteryUnrestricted", power != null && power.isIgnoringBatteryOptimizations(context.getPackageName()));
        out.put("exactAlarms", Wake.canScheduleExact(context));
        NotificationManager notifications = context.getSystemService(NotificationManager.class);
        out.put("notifications", notifications != null && notifications.areNotificationsEnabled());
        boolean restricted = false;
        if (Build.VERSION.SDK_INT >= 28) {
            ActivityManager am = context.getSystemService(ActivityManager.class);
            restricted = am != null && am.isBackgroundRestricted();
        }
        out.put("backgroundRestricted", restricted);
        out.put("overlay", Settings.canDrawOverlays(context));
        return out;
    }

    /** Opens the screen for [kind]; returns false when no screen could be opened. */
    static boolean open(Context context, String kind) {
        String pkg = context.getPackageName();
        Uri uri = Uri.parse("package:" + pkg);
        switch (kind) {
            case "autostart": {
                String[] screens = AUTOSTART.get(maker());
                if (screens != null) {
                    for (String screen : screens) {
                        if (start(context, new Intent().setComponent(ComponentName.unflattenFromString(screen)))) return true;
                    }
                }
                return start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
            }
            case "battery":
                return start(context, new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, uri))
                    || start(context, new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    || start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
            case "exactAlarms":
                if (Build.VERSION.SDK_INT >= 31
                    && start(context, new Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, uri))) return true;
                return start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
            case "notifications":
                return start(context, new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, pkg))
                    || start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
            case "overlay":
                return start(context, new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, uri))
                    || start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
            case "tts":
                return start(context, new Intent("com.android.settings.TTS_SETTINGS"))
                    || start(context, new Intent(Settings.ACTION_SETTINGS));
            default:
                return start(context, new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri));
        }
    }

    private static boolean start(Context context, Intent intent) {
        try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
            return true;
        } catch (RuntimeException e) {
            // Not on this phone (ActivityNotFoundException) or not allowed (SecurityException).
            return false;
        }
    }
}
