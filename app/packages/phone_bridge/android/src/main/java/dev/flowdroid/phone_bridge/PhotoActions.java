package dev.flowdroid.phone_bridge;

import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.provider.OpenableColumns;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/** Photos from the camera or the gallery, copied into FlowDroid's folder. */
final class PhotoActions {
    private PhotoActions() {}

    /** FlowDroid's folder for files (Ubuntu sees it as /root/files). */
    static File filesDir(Context context) {
        return new File(context.getDir("flutter", Context.MODE_PRIVATE), "files");
    }

    /** Where the camera app writes the photo before FlowDroid copies it (shareable through the FileProvider). */
    static File cameraTarget(Context context) throws IOException {
        File dir = new File(context.getCacheDir(), "flowdroid-share");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("no cache folder");
        return new File(dir, "camera-" + System.currentTimeMillis() + ".jpg");
    }

    static Intent cameraIntent(Context context, File target) {
        Uri uri = FileProvider.getUriForFile(context, context.getPackageName() + ".flowdroid.files", target);
        return new Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            .putExtra(MediaStore.EXTRA_OUTPUT, uri)
            .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION | Intent.FLAG_GRANT_READ_URI_PERMISSION);
    }

    /** Android's photo picker where there is one, else any app that picks images. */
    static Intent galleryIntent(boolean multiple) {
        if (Build.VERSION.SDK_INT >= 33) {
            Intent pick = new Intent(MediaStore.ACTION_PICK_IMAGES);
            if (multiple) pick.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit());
            return pick;
        }
        return new Intent(Intent.ACTION_GET_CONTENT)
            .setType("image/*")
            .addCategory(Intent.CATEGORY_OPENABLE)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple);
    }

    /** Copies [uri] into files/<folder>; returns its path inside FlowDroid's folder, e.g. `photos/123-a.jpg`. */
    static String copyIn(Context context, Uri uri, String folder, String fallbackName) throws IOException {
        File dir = new File(filesDir(context), folder);
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("could not make the " + folder + " folder");
        String name = displayName(context, uri, fallbackName);
        File target = new File(dir, System.currentTimeMillis() + "-" + name);
        try (InputStream in = context.getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(target)) {
            if (in == null) throw new IOException("could not read " + name);
            byte[] buffer = new byte[64 * 1024];
            for (int n = in.read(buffer); n > 0; n = in.read(buffer)) out.write(buffer, 0, n);
        }
        return folder + "/" + target.getName();
    }

    /** Moves the camera's photo into files/photos. */
    static String keepCameraPhoto(Context context, File photo) throws IOException {
        if (!photo.isFile() || photo.length() == 0) throw new IOException("the camera saved no photo");
        String path = copyIn(context, Uri.fromFile(photo), "photos", "photo.jpg");
        //noinspection ResultOfMethodCallIgnored
        photo.delete();
        return path;
    }

    private static String displayName(Context context, Uri uri, String fallback) {
        String name = null;
        if ("content".equals(uri.getScheme())) {
            try (Cursor c = context.getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (c != null && c.moveToFirst() && !c.isNull(0)) name = c.getString(0);
            } catch (RuntimeException ignored) {
                // Use the fallback name.
            }
        } else if (uri.getLastPathSegment() != null) {
            name = uri.getLastPathSegment();
        }
        if (name == null || name.isEmpty()) name = fallback;
        return name.replaceAll("[^A-Za-z0-9._-]", "_");
    }
}
