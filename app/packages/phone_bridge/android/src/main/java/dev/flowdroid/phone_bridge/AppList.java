package dev.flowdroid.phone_bridge;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** The phone's apps, for choosing one by name and icon instead of typing its package. */
final class AppList {
    private static final String PREFS = "flowdroid_recent_notifiers";
    private static final String KEY = "packages";
    private static final int KEEP = 20;
    private static final int ICON_PX = 96;

    private AppList() {}

    /** Remembers that [pkg] posted a notification, newest first. */
    static void notified(Context context, String pkg) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String old = prefs.getString(KEY, "");
        StringBuilder out = new StringBuilder(pkg);
        int n = 1;
        for (String p : old.split(",")) {
            if (p.isEmpty() || p.equals(pkg)) continue;
            if (n++ >= KEEP) break;
            out.append(',').append(p);
        }
        prefs.edit().putString(KEY, out.toString()).apply();
    }

    private static List<String> recent(Context context) {
        String saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "");
        List<String> out = new ArrayList<>();
        for (String p : saved.split(",")) if (!p.isEmpty()) out.add(p);
        return out;
    }

    /** Apps with a launcher icon, plus any that recently posted notifications. Slow: call off the main thread. */
    static List<Map<String, Object>> installed(Context context) {
        PackageManager pm = context.getPackageManager();
        List<String> recent = recent(context);
        Set<String> seen = new HashSet<>();
        List<Map<String, Object>> apps = new ArrayList<>();
        Intent launcher = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        for (ResolveInfo info : pm.queryIntentActivities(launcher, 0)) {
            String pkg = info.activityInfo.packageName;
            if (pkg.equals(context.getPackageName()) || !seen.add(pkg)) continue;
            apps.add(app(pm, pkg, info.loadLabel(pm).toString(), info.loadIcon(pm), recent.indexOf(pkg)));
        }
        // System apps without a launcher icon (e.g. the phone's messages service) can post notifications too.
        for (String pkg : recent) {
            if (!seen.add(pkg)) continue;
            try {
                android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                apps.add(app(pm, pkg, pm.getApplicationLabel(ai).toString(), pm.getApplicationIcon(ai), recent.indexOf(pkg)));
            } catch (PackageManager.NameNotFoundException ignored) {
                // Uninstalled since.
            }
        }
        return apps;
    }

    private static Map<String, Object> app(PackageManager pm, String pkg, String label, Drawable icon, int recentRank) {
        Map<String, Object> m = new HashMap<>();
        m.put("package", pkg);
        m.put("label", label);
        m.put("recent", recentRank);
        m.put("icon", png(icon));
        return m;
    }

    private static byte[] png(Drawable icon) {
        try {
            Bitmap bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(bitmap);
            icon.setBounds(0, 0, ICON_PX, ICON_PX);
            icon.draw(canvas);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
            bitmap.recycle();
            return out.toByteArray();
        } catch (RuntimeException e) {
            return new byte[0];
        }
    }
}
