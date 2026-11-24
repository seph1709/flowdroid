package dev.flowdroid.phone_bridge;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.function.Consumer;

/**
 * Shows a browser session on screen: to watch (and step into) a run, or to log
 * in to a site once so workflows and the AI Agent can use that login.
 */
public class BrowserActivity extends Activity {
    static final String EXTRA_SESSION = "session";
    static final String EXTRA_LOGIN = "login";

    private static final Map<String, BrowserActivity> OPEN = new HashMap<>();
    private static final Map<String, Done> ON_DONE = new HashMap<>();
    /**
     * Sessions asked to close while their window was still starting. startActivity is
     * asynchronous, so a quick run can hide the page before the window exists; without
     * this the window would then open anyway and stay on screen.
     */
    private static final Set<String> CLOSE_PENDING = new HashSet<>();

    /** A Done callback, tied to the session it was made for (not just its id). */
    private static final class Done {
        final Browser.Session session;
        final Consumer<String> callback;

        Done(Browser.Session session, Consumer<String> callback) {
            this.session = session;
            this.callback = callback;
        }
    }

    private String sessionId;
    /** The session this window shows; a later session with the same id is not ours. */
    private Browser.Session session;
    private TextView address;
    private Button button;
    private boolean login;

    static boolean isOpen(String id) {
        return OPEN.containsKey(id);
    }

    /**
     * Says whether FlowDroid is still working in the page on screen. A finished run
     * leaves its page up so the person can see the result; they close it themselves.
     */
    static void status(String id, boolean running) {
        BrowserActivity activity = OPEN.get(id);
        if (activity != null && !activity.login) activity.showStatus(running);
    }

    private void showStatus(boolean running) {
        address.setText(running ? "FlowDroid is using this page" : "Finished · tap Close when you're done");
        button.setText(running ? "Hide" : "Close");
    }

    /** Calls [done] with the page's address once the person taps Done (or leaves). */
    static void onDone(String id, Consumer<String> done) {
        ON_DONE.put(id, new Done(Browser.get(id), done));
    }

    /** Takes back a Done callback nobody has answered yet (so it can be answered now). */
    static Consumer<String> takeDone(String id) {
        Done d = ON_DONE.remove(id);
        return d == null ? null : d.callback;
    }

    /** Called right before a window for [id] is started: an earlier close no longer applies. */
    static void opening(String id) {
        CLOSE_PENDING.remove(id);
    }

    static void closeFor(String id) {
        BrowserActivity activity = OPEN.remove(id);
        if (activity != null) {
            activity.finish();
        } else {
            CLOSE_PENDING.add(id);
        }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        sessionId = getIntent().getStringExtra(EXTRA_SESSION);
        Browser.Session found = sessionId == null ? null : Browser.get(sessionId);
        if (found == null || found.dead || CLOSE_PENDING.remove(sessionId)) {
            // Gone, or hidden again before this window got to start.
            finish();
            return;
        }
        session = found;
        login = getIntent().getBooleanExtra(EXTRA_LOGIN, false);
        session.shown = true;
        BrowserActivity older = OPEN.put(sessionId, this);
        if (older != null && older != this) older.finish();

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);
        root.setFitsSystemWindows(true);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        int pad = dp(12);
        bar.setPadding(pad, dp(6), dp(6), dp(6));
        address = new TextView(this);
        address.setSingleLine(true);
        address.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        address.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        address.setTextColor(Color.rgb(0x6E, 0x6E, 0x73));
        address.setText(login ? "Log in, then tap Done" : "FlowDroid is using this page");
        bar.addView(address, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        button = new Button(this);
        button.setText(login ? "Done" : "Hide");
        button.setOnClickListener(v -> finish());
        bar.addView(button);
        root.addView(bar);

        WebView web = session.web;
        ViewGroup parent = (ViewGroup) web.getParent();
        if (parent != null) parent.removeView(web);
        root.addView(web, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(root);
    }

    @Override
    public void onBackPressed() {
        if (session != null && !session.dead && session.web.canGoBack()) {
            session.web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        if (sessionId != null && session != null) {
            if (OPEN.get(sessionId) == this) OPEN.remove(sessionId);
            // A newer window already shows this page: leave the page and its callback to it.
            boolean replaced = OPEN.containsKey(sessionId);
            String url = "";
            if (!session.dead) url = session.web.getUrl() == null ? "" : session.web.getUrl();
            if (!replaced && !session.dead && Browser.get(sessionId) == session) {
                session.shown = false;
                // Back to running headless, at phone-screen size.
                Browser.hideHeadless(this, session);
                session.touch();
            }
            CookieManager.getInstance().flush();
            Done done = ON_DONE.get(sessionId);
            if (!replaced && done != null && done.session == session) {
                ON_DONE.remove(sessionId);
                done.callback.accept(url);
            }
        }
        super.onDestroy();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
