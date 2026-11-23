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
import android.graphics.PixelFormat;
import android.os.Build;
import android.provider.Settings;
import android.view.WindowManager;
import android.widget.FrameLayout;

import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;

import java.util.Collections;
import android.webkit.CookieManager;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
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
        /** Set once the WebView is destroyed (closed, or its renderer died): no call may touch it again. */
        boolean dead;
        /** The load in progress has started (so its "finished" is not a leftover of the page before). */
        boolean started;
        int httpStatus;
        /** The invisible overlay window that keeps a hidden page rendering, if any. */
        FrameLayout host;
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
        if (existing != null && existing.dead) {
            SESSIONS.remove(id);
            existing = null;
        }
        if (existing != null) {
            existing.fast = fast;
            existing.web.getSettings().setBlockNetworkImage(fast);
            existing.touch();
            return existing;
        }
        WebView web;
        try {
            web = new WebView(context.getApplicationContext());
        } catch (Throwable t) {
            // The system WebView is missing, disabled or being updated.
            throw new IllegalStateException("the phone's WebView could not start (" + t.getMessage()
                + "); update “Android System WebView” in the Play Store", t);
        }
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
        if (Build.VERSION.SDK_INT >= 26) {
            // Keep the page's renderer alive while FlowDroid works in the background.
            web.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false);
        }
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int progress) {
                // Some pages report 100% well before (or instead of) onPageFinished.
                if (progress >= 100 && session.started) loaded(session, view.getUrl());
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageStarted(WebView view, String url, Bitmap favicon) {
                session.started = true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                // A finish without a start is the page before (stopped), not this load.
                if (session.started) loaded(session, url);
                flushCookiesSoon();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (!request.isForMainFrame()) return;
                session.finishLoad(error("could not load " + request.getUrl() + ": " + error.getDescription()));
            }

            @Override
            public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse response) {
                if (request.isForMainFrame()) session.httpStatus = response.getStatusCode();
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                // Without this Android kills all of FlowDroid along with the page. Drop the
                // session instead; the next step makes a fresh one.
                boolean crashed = Build.VERSION.SDK_INT < 26 || detail.didCrash();
                session.dead = true;
                if (SESSIONS.get(session.id) == session) SESSIONS.remove(session.id);
                session.finishLoad(error(crashed
                    ? "the page crashed the browser; it restarts on the next try"
                    : "Android closed the browser to free memory; it restarts on the next try"));
                BrowserActivity.closeFor(session.id);
                removeHost(session);
                destroy(view);
                return true;
            }

            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                if (session.fast && !request.isForMainFrame() && heavy(request.getUrl())) {
                    return new WebResourceResponse("text/plain", "utf-8", new ByteArrayInputStream(new byte[0]));
                }
                return null;
            }
        });
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            try {
                WebViewCompat.addDocumentStartJavaScript(web, VISIBLE_SHIM, Collections.singleton("*"));
            } catch (Throwable ignored) {
                // Old WebView: pages still work, some only less well while hidden.
            }
        }
        hideHeadless(context, session);
        web.resumeTimers();
        SESSIONS.put(id, session);
        session.touch();
        return session;
    }

    private static void loaded(Session session, String url) {
        if (session.onLoaded == null || session.dead) return;
        Map<String, Object> page = new HashMap<>();
        page.put("url", url == null ? "" : url);
        page.put("title", session.web.getTitle() == null ? "" : session.web.getTitle());
        if (session.httpStatus >= 400) page.put("status", session.httpStatus);
        session.finishLoad(page);
    }

    private static final Runnable FLUSH = () -> CookieManager.getInstance().flush();

    /** Saves logins to disk shortly after pages load, so they survive FlowDroid being closed. */
    private static void flushCookiesSoon() {
        MAIN.removeCallbacks(FLUSH);
        MAIN.postDelayed(FLUSH, 2000);
    }

    private static void destroy(WebView web) {
        try {
            ViewGroup parent = (ViewGroup) web.getParent();
            if (parent != null) parent.removeView(web);
            web.stopLoading();
            web.destroy();
        } catch (Throwable ignored) {
            // Already gone.
        }
    }

    /**
     * Pages check whether they are on screen: a hidden one gets no animation frames, so
     * lazy content never loads and some apps never draw. Tell them they are visible, and
     * keep requestAnimationFrame callbacks coming even when no frame is drawn.
     */
    private static final String VISIBLE_SHIM = "(function(){try{"
        + "Object.defineProperty(document,'visibilityState',{get:function(){return 'visible'},configurable:true});"
        + "Object.defineProperty(document,'hidden',{get:function(){return false},configurable:true});"
        + "var raf=window.requestAnimationFrame.bind(window);"
        + "window.requestAnimationFrame=function(cb){var done=false;"
        + "var run=function(t){if(!done){done=true;cb(t||performance.now());}};"
        + "var id=raf(run);setTimeout(run,100);return id;};"
        + "}catch(e){}})();";

    /**
     * Runs a session headless. With "display over other apps" allowed, the page goes into
     * an invisible 1×1 window, so Chrome renders it exactly like a page on screen (frames,
     * lazy loading, animations) even while FlowDroid is in the background. Without it, the
     * page runs detached at phone-screen size.
     */
    static void hideHeadless(Context context, Session session) {
        WebView web = session.web;
        ViewGroup parent = (ViewGroup) web.getParent();
        if (parent != null) parent.removeView(web);
        layOut(web);
        Context app = context.getApplicationContext();
        if (session.host != null || !Settings.canDrawOverlays(app)) {
            if (session.host != null) session.host.addView(web, new FrameLayout.LayoutParams(WIDTH, HEIGHT));
            return;
        }
        try {
            FrameLayout host = new FrameLayout(app);
            host.setAlpha(0f);
            host.addView(web, new FrameLayout.LayoutParams(WIDTH, HEIGHT));
            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(1, 1,
                Build.VERSION.SDK_INT >= 26 ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                    : WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
                    | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
            lp.alpha = 0f;
            app.getSystemService(WindowManager.class).addView(host, lp);
            session.host = host;
        } catch (Throwable t) {
            // No overlay after all: run detached.
            ViewGroup p = (ViewGroup) web.getParent();
            if (p != null) p.removeView(web);
            layOut(web);
        }
    }

    private static void removeHost(Session session) {
        FrameLayout host = session.host;
        session.host = null;
        if (host == null) return;
        try {
            host.removeAllViews();
            host.getContext().getSystemService(WindowManager.class).removeView(host);
        } catch (Throwable ignored) {
            // Already removed.
        }
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
        Session session;
        try {
            session = session(context, id, fast);
        } catch (RuntimeException e) {
            done.accept(error(e.getMessage()));
            return;
        }
        session.finishLoad(error("another page was opened"));
        session.onLoaded = done;
        session.started = false;
        session.httpStatus = 0;
        session.timeout = () -> {
            // Slow pages: carry on with what has loaded, as a person would.
            if (session.dead) return;
            Map<String, Object> page = new HashMap<>();
            page.put("url", session.web.getUrl() == null ? url : session.web.getUrl());
            page.put("title", session.web.getTitle() == null ? "" : session.web.getTitle());
            page.put("slow", true);
            session.finishLoad(page);
        };
        MAIN.postDelayed(session.timeout, Math.max(1000, timeoutMs));
        try {
            session.web.stopLoading();
            session.web.loadUrl(url);
        } catch (Throwable t) {
            session.finishLoad(error("could not open " + url + ": " + t.getMessage()));
        }
    }

    /** Runs [js] in the page; [done] gets its result as JSON text, or null when there is no session. */
    static void eval(String id, String js, Consumer<String> done) {
        Session session = SESSIONS.get(id);
        if (session == null) {
            done.accept(null);
            return;
        }
        if (session.dead) {
            done.accept(null);
            return;
        }
        session.touch();
        try {
            session.web.evaluateJavascript(js, done::accept);
        } catch (Throwable t) {
            done.accept(null);
        }
    }

    static boolean back(String id) {
        Session session = SESSIONS.get(id);
        if (session == null || session.dead || !session.web.canGoBack()) return false;
        try {
            session.web.goBack();
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /** Saves what the page shows now as a PNG at [file]. */
    static Map<String, Object> screenshot(String id, File file) {
        Session session = SESSIONS.get(id);
        if (session == null || session.dead) return error("no page is open");
        WebView web = session.web;
        if (web.getWidth() == 0 || web.getHeight() == 0) layOut(web);
        Bitmap bitmap;
        try {
            bitmap = Bitmap.createBitmap(web.getWidth(), web.getHeight(), Bitmap.Config.ARGB_8888);
            web.draw(new Canvas(bitmap));
        } catch (Throwable t) {
            return error("could not take the screenshot (low memory?): " + t.getMessage());
        }
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
        removeHost(session);
        if (!session.dead) destroy(session.web);
        session.dead = true;
        CookieManager.getInstance().flush();
    }

    static String cookies(String url) {
        String c = CookieManager.getInstance().getCookie(url);
        return c == null ? "" : c;
    }

    /** Logs out of one site: expires every cookie the browser would send to [url] and its parent domains. */
    static void forget(String url) {
        CookieManager cm = CookieManager.getInstance();
        String host = Uri.parse(url).getHost();
        if (host == null) return;
        String[] parts = host.split("\\.");
        for (int i = 0; i < parts.length - 1; i++) {
            StringBuilder domain = new StringBuilder();
            for (int j = i; j < parts.length; j++) domain.append(j == i ? "" : ".").append(parts[j]);
            String base = "https://" + domain;
            String cookies = cm.getCookie(base);
            if (cookies == null) continue;
            for (String c : cookies.split(";")) {
                String name = c.split("=", 2)[0].trim();
                if (name.isEmpty()) continue;
                for (String scope : new String[] {"", "; domain=" + domain, "; domain=." + domain}) {
                    cm.setCookie(base, name + "=; Max-Age=0; path=/" + scope);
                }
            }
        }
        cm.flush();
        WebStorage.getInstance().deleteOrigin("https://" + host);
        WebStorage.getInstance().deleteOrigin("http://" + host);
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
