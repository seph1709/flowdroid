package dev.flowdroid.phone_bridge;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Opens or shares a file from FlowDroid's folder with another app. */
final class FileActions {
    private FileActions() {}

    /** A content:// link another app may read, for a copy of [path] in the shared cache. */
    private static Uri shareable(Context context, String path) throws IOException {
        File source = new File(path);
        File dir = new File(context.getCacheDir(), "flowdroid-share");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("no cache folder");
        File copy = new File(dir, source.getName());
        try (InputStream in = new FileInputStream(source); OutputStream out = new FileOutputStream(copy)) {
            byte[] buffer = new byte[64 * 1024];
            for (int n = in.read(buffer); n > 0; n = in.read(buffer)) out.write(buffer, 0, n);
        }
        return FileProvider.getUriForFile(context, context.getPackageName() + ".flowdroid.files", copy);
    }

    /** Null when it opened, else why not. */
    static String open(Context context, String path, String mime) {
        try {
            Intent view = new Intent(Intent.ACTION_VIEW)
                .setDataAndType(shareable(context, path), mime)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(view);
            return null;
        } catch (ActivityNotFoundException e) {
            return "no app on this phone opens " + mime + " files";
        } catch (Exception e) {
            return "could not open the file: " + e.getMessage();
        }
    }

    static String share(Context context, String path, String mime) {
        try {
            Intent send = new Intent(Intent.ACTION_SEND)
                .setType(mime)
                .putExtra(Intent.EXTRA_STREAM, shareable(context, path))
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            return null;
        } catch (Exception e) {
            return "could not share the file: " + e.getMessage();
        }
    }
}
