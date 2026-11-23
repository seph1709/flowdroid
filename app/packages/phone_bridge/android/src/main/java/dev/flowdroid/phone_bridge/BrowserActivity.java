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
import java.util.Map;
import java.util.function.Consumer;

/**
 * Shows a browser session on screen: to watch (and step into) a run, or to log
 * in to a site once so workflows and the AI Agent can use that login.
 */
public class BrowserActivity extends Activity {
    static final String EXTRA_SESSION = "session";
    static final String EXTRA_LOGIN = "login";

    private static final Map<String, BrowserActivity> OPEN = new HashMap<>();
    private static final Map<String, Consumer<String>> ON_DONE = new HashMap<>();

    private String sessionId;
    private TextView address;

    /** Calls [done] with the page's address once the person taps Done (or leaves). */
    static void onDone(String session, Consumer<String> done) {
        ON_DONE.put(session, done);
    }

    static void closeFor(String session) {
        BrowserActivity activity = OPEN.remove(session);
        if (activity != null) activity.finish();
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        sessionId = getIntent().getStringExtra(EXTRA_SESSION);
        Browser.Session session = sessionId == null ? null : Browser.get(sessionId);
        if (session == null) {
            finish();
            return;
        }
        boolean login = getIntent().getBooleanExtra(EXTRA_LOGIN, false);
        session.shown = true;
        OPEN.put(sessionId, this);

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
        Button done = new Button(this);
        done.setText(login ? "Done" : "Hide");
        done.setOnClickListener(v -> finish());
        bar.addView(done);
        root.addView(bar);

        WebView web = session.web;
        ViewGroup parent = (ViewGroup) web.getParent();
        if (parent != null) parent.removeView(web);
        root.addView(web, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        setContentView(root);
    }

    @Override
    public void onBackPressed() {
        Browser.Session session = sessionId == null ? null : Browser.get(sessionId);
        if (session != null && session.web.canGoBack()) {
            session.web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        if (sessionId != null) {
            if (OPEN.get(sessionId) == this) OPEN.remove(sessionId);
            Browser.Session session = Browser.get(sessionId);
            String url = "";
            if (session != null) {
                session.shown = false;
                url = session.web.getUrl() == null ? "" : session.web.getUrl();
                // Back to running hidden, at phone-screen size.
                ViewGroup parent = (ViewGroup) session.web.getParent();
                if (parent != null) parent.removeView(session.web);
                Browser.layOut(session.web);
                session.touch();
            }
            CookieManager.getInstance().flush();
            Consumer<String> done = ON_DONE.remove(sessionId);
            if (done != null) done.accept(url);
        }
        super.onDestroy();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
