package dev.flowdroid.phone_bridge;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebStorage;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.function.Consumer;

/**
 * FlowDroid's in-app browser: WebView sessions that workflows and the AI Agent
 * drive. Sessions stay warm between runs (no start-up cost after the first),
 * share the app's cookies (so logins made in the login screen are used), and in
 * fast mode skip images, fonts and media. All calls are on the main thread.
 */
final class Browser {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final Map<String, Session> SESSIONS = new HashMap<>();
    /** A session nobody used for this long is closed. */
    private static final long IDLE_MS = 5 * 60_000;
    private static final int WIDTH = 1080;
    private static final int HEIGHT = 2280;

    private Browser() {}

    /** One WebView and what it is waiting for. */
    static final class Session {
        final String id;
        final WebView web;
        boolean fast;
        boolean shown;
        private Consumer<Map<String, Object>> onLoaded;
        private Runnable timeout;
        private final Runnable idle;

        Session(String id, WebView web) {
            this.id = id;
            this.web = web;
            this.idle = () -> {
                if (!shown) close(id);
            };
        }

        void touch() {
            MAIN.removeCallbacks(idle);
            MAIN.postDelayed(idle, IDLE_MS);
        }

        void finishLoad(Map<String, Object> answer) {
            Consumer<Map<String, Object>> done = onLoaded;
            onLoaded = null;
            if (timeout != null) MAIN.removeCallbacks(timeout);
            timeout = null;
            if (done != null) done.accept(answer);
        }
    }

    static Session get(String id) {
        return SESSIONS.get(id);
    }

    /** The session [id], made the first time (warm afterwards). */
    @SuppressLint("SetJavaScriptEnabled")
    static Session session(Context context, String id, boolean fast) {
        Session existing = SESSIONS.get(id);
        if (existing != null) {
            existing.fast = fast;
            existing.web.getSettings().setBlockNetworkImage(fast);
            existing.touch();
            return existing;
        }
        WebView web = new WebView(context.getApplicationContext());
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setBlockNetworkImage(fast);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        // Look like the phone's browser, not an embedded WebView, which some sites treat differently.
        s.setUserAgentString(s.getUserAgentString().replace("; wv", "").replaceAll("Version/\\d+(\\.\\d+)* ", ""));
        CookieManager cookies = CookieManager.getInstance();
        cookies.setAcceptCookie(true);
        cookies.setAcceptThirdPartyCookies(web, true);
        web.setBackgroundColor(Color.WHITE);
        Session session = new Session(id, web);
        session.fast = fast;
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                if (view.getProgress() < 100) return;
                Map<String, Object> page = new HashMap<>();
                page.put("url", url);
                page.put("title", view.getTitle() == null ? "" : view.getTitle());
                session.finishLoad(page);
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) return;
                session.finishLoad(error("could not load " + request.getUrl() + ": " + error.getDescription()));
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                if (session.fast && !request.isForMainFrame() && heavy(request.getUrl())) {
                    return new WebResourceResponse("text/plain", "utf-8", new ByteArrayInputStream(new byte[0]));
                }
                return null;
            }
        });
        layOut(web);
        web.resumeTimers();
        SESSIONS.put(id, session);
        session.touch();
        return session;
    }

    /** A hidden WebView still needs a size, so pages lay out like on a phone screen. */
    static void layOut(WebView web) {
        web.measure(View.MeasureSpec.makeMeasureSpec(WIDTH, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(HEIGHT, View.MeasureSpec.EXACTLY));
        web.layout(0, 0, WIDTH, HEIGHT);
    }

    /** Images, fonts and media: what fast mode doesn't download. */
    private static boolean heavy(Uri uri) {
        String path = uri.getPath() == null ? "" : uri.getPath().toLowerCase(Locale.ROOT);
        int dot = path.lastIndexOf('.');
        if (dot < 0) return false;
        switch (path.substring(dot + 1)) {
            case "png": case "jpg": case "jpeg": case "gif": case "webp": case "avif": case "svg": case "ico": case "bmp":
            case "woff": case "woff2": case "ttf": case "otf": case "eot":
            case "mp4": case "webm": case "m3u8": case "ts": case "mp3": case "m4a": case "ogg": case "wav":
                return true;
            default:
                return false;
        }
    }

    /** Loads [url]; [done] gets `{url, title}` once it finished, or `{error}`. */
    static void open(Context context, String id, String url, boolean fast, long timeoutMs, Consumer<Map<String, Object>> done) {
        Session session = session(context, id, fast);
        session.finishLoad(error("another page was opened"));
        session.onLoaded = done;
        session.timeout = () -> {
            // Slow pages: carry on with what has loaded, as a person would.
            Map<String, Object> page = new HashMap<>();
            page.put("url", session.web.getUrl());
            page.put("title", session.web.getTitle() == null ? "" : session.web.getTitle());
            page.put("slow", true);
            session.finishLoad(page);
        };
        MAIN.postDelayed(session.timeout, Math.max(1000, timeoutMs));
        session.web.loadUrl(url);
    }

    /** Runs [js] in the page; [done] gets its result as JSON text, or null when there is no session. */
    static void eval(String id, String js, Consumer<String> done) {
        Session session = SESSIONS.get(id);
        if (session == null) {
            done.accept(null);
            return;
        }
        session.touch();
        session.web.evaluateJavascript(js, done::accept);
    }

    static boolean back(String id) {
        Session session = SESSIONS.get(id);
        if (session == null || !session.web.canGoBack()) return false;
        session.web.goBack();
        return true;
    }

    /** Saves what the page shows now as a PNG at [file]. */
    static Map<String, Object> screenshot(String id, File file) {
        Session session = SESSIONS.get(id);
        if (session == null) return error("no page is open");
        WebView web = session.web;
        if (web.getWidth() == 0 || web.getHeight() == 0) layOut(web);
        Bitmap bitmap = Bitmap.createBitmap(web.getWidth(), web.getHeight(), Bitmap.Config.ARGB_8888);
        web.draw(new Canvas(bitmap));
        File dir = file.getParentFile();
        if (dir != null && !dir.isDirectory() && !dir.mkdirs()) return error("could not make the screenshots folder");
        try (FileOutputStream out = new FileOutputStream(file)) {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        } catch (Exception e) {
            return error("could not save the screenshot: " + e.getMessage());
        } finally {
            bitmap.recycle();
        }
        Map<String, Object> out = new HashMap<>();
        out.put("width", web.getWidth());
        out.put("height", web.getHeight());
        return out;
    }

    static void close(String id) {
        Session session = SESSIONS.remove(id);
        if (session == null) return;
        session.finishLoad(error("the browser was closed"));
        BrowserActivity.closeFor(id);
        ViewGroup parent = (ViewGroup) session.web.getParent();
        if (parent != null) parent.removeView(session.web);
        session.web.stopLoading();
        session.web.destroy();
        CookieManager.getInstance().flush();
    }

    static String cookies(String url) {
        String c = CookieManager.getInstance().getCookie(url);
        return c == null ? "" : c;
    }

    /** Logs out of every site: cookies and site storage. */
    static void clearLogins() {
        CookieManager.getInstance().removeAllCookies(null);
        CookieManager.getInstance().flush();
        WebStorage.getInstance().deleteAllData();
    }

    static Map<String, Object> error(String message) {
        Map<String, Object> out = new HashMap<>();
        out.put("error", message);
        return out;
    }
}
