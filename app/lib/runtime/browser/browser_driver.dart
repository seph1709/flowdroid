import 'dart:async';
import 'dart:convert';

import '../../core/json.dart';

/// The browser the driver works with: the phone's in-app browser in the app
/// (see `PhoneBridge.browser*`), or a fake in tests.
abstract interface class BrowserPage {
  /// Loads [url]; `{url, title}` or `{error}`.
  Future<JsonMap> open(String session, String url, {required bool fast, required int timeoutMs});

  /// Runs [js] in the page; its result as JSON text, or null when there is no page.
  Future<String?> eval(String session, String js);

  Future<bool> back(String session);

  /// Saves what the page shows as a PNG at [path] in FlowDroid's folder; `{}` or `{error}`.
  Future<JsonMap> screenshot(String session, String path);

  /// Puts the session on screen; `{}` or `{error}`.
  Future<JsonMap> show(String session);

  Future<void> hide(String session);

  /// The run on screen is over: the page stays up, marked finished, until the person closes it.
  Future<void> finished(String session);
}

/// Something wrong with a step: its message ends up as the node's error.
class BrowserException implements Exception {
  const BrowserException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One parsed line of a Browser step's script.
class BrowserCommand {
  const BrowserCommand(
    this.line,
    this.verb, {
    this.target = '',
    this.text = '',
    this.name = '',
    this.all = false,
    this.attr = '',
  });

  final int line;
  final String verb;
  final String target;
  final String text;
  final String name;
  final bool all;
  final String attr;

  @override
  String toString() => '$line:$verb target=$target text=$text name=$name all=$all attr=$attr';
}

/// Runs Browser steps and the AI Agent's browser tool on a [BrowserPage].
///
/// Built for speed: nothing sleeps for a fixed time. After an action the
/// driver polls the page (every [poll]) until it has finished loading and its
/// content has stopped changing for [quiet], and each action is one small
/// call into the page.
class BrowserDriver {
  BrowserDriver(
    this.page, {
    required this.saveScreenshot,
    this.poll = const Duration(milliseconds: 50),
    this.quiet = const Duration(milliseconds: 250),
    this.elementWaitMs = 10000,
  });

  final BrowserPage page;

  /// Turns a screenshot's path in FlowDroid's folder into a file reference `{path, name, mimeType, size}`.
  final Future<JsonMap> Function(String path) saveScreenshot;
  final Duration poll;
  final Duration quiet;

  /// Sessions are per driver: the app on screen and the background service each
  /// have one, so a run in one never takes over the other's page.
  /// The clock alone is not enough: two drivers made within one clock tick would share it.
  final _tag = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_made++}';
  static int _made = 0;
  int _shots = 0;

  /// The session Browser steps share (kept warm between runs); one run at a time.
  String get runSession => 'run-$_tag';
  String get agentSession => 'agent-$_tag';

  /// The longest a step waits for its element to show up before failing.
  final int elementWaitMs;

  /// The longest one call into the page may take.
  static const callTimeout = Duration(seconds: 20);
  Future<void> _queue = Future.value();

  // ---------------------------------------------------------------- the `browser` effect

  /// `{runs: [{url, steps}], visible, fast, timeoutMs}` → `{results: [{url, title, data, screenshots} | {error}]}`.
  Future<JsonMap> call(JsonMap effect) {
    final done = Completer<JsonMap>();
    _queue = _queue.then((_) async {
      final results = <JsonMap>[];
      for (final run in asMapList(effect['runs'])) {
        final timeoutMs = asInt(effect['timeoutMs'], 60000);
        try {
          results.add(
            await runWithRetry(
              asString(run['url']),
              asString(run['steps']),
              visible: effect['visible'] == true,
              fast: effect['fast'] == true,
              timeoutMs: timeoutMs,
            ).timeout(Duration(milliseconds: timeoutMs * 2)),
          );
        } on TimeoutException {
          results.add({
            'error': 'the steps did not finish within ${(timeoutMs / 1000).round()} s${await glance(runSession)}',
          });
        } on BrowserException catch (e) {
          results.add({'error': e.message});
        } on Exception catch (e) {
          results.add({'error': '$e'});
        }
      }
      done.complete({'results': results});
    });
    return done.future;
  }

  /// [runScript], tried once more when the browser crashed or the network
  /// failed before the script clicked or typed anything (so nothing is done twice).
  Future<JsonMap> runWithRetry(
    String url,
    String script, {
    bool visible = false,
    bool fast = true,
    int timeoutMs = 60000,
  }) async {
    final progress = BrowserProgress();
    try {
      return await runScript(
        url,
        script,
        visible: visible,
        fast: fast,
        timeoutMs: timeoutMs,
        progress: progress,
      ).timeout(Duration(milliseconds: timeoutMs));
    } on BrowserException catch (e) {
      if (progress.acted || !isRetryable(e.message)) rethrow;
    } on TimeoutException {
      progress.stopped = true;
      if (progress.acted) rethrow;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    final again = BrowserProgress();
    return runScript(url, script, visible: visible, fast: fast, timeoutMs: timeoutMs, progress: again).timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () {
        again.stopped = true;
        throw TimeoutException('the steps did not finish', Duration(milliseconds: timeoutMs));
      },
    );
  }

  /// Failures that a fresh try can fix: a crashed or closed browser, or a network blip.
  static bool isRetryable(String message) => RegExp(
    r'crashed the browser|closed the browser|page is not open|stopped answering|ERR_(CONNECTION|TIMED_OUT|NETWORK_CHANGED|INTERNET_DISCONNECTED|ADDRESS_UNREACHABLE|EMPTY_RESPONSE)',
  ).hasMatch(message);

  /// Opens [url], runs each line of [script], and returns where it ended up and what it extracted.
  Future<JsonMap> runScript(
    String url,
    String script, {
    bool visible = false,
    bool fast = true,
    int timeoutMs = 60000,
    BrowserProgress? progress,
  }) async {
    final commands = parse(script);
    final s = runSession;
    final waitMs = timeoutMs < elementWaitMs ? timeoutMs : elementWaitMs;
    Future<void> appear(String target) => _appear(s, target, waitMs);
    // Clicking and typing also wait for the element to be enabled.
    Future<void> ready(String target) => _appear(s, target, waitMs, check: 'actionable');
    final data = <String, Object?>{};
    final screenshots = <JsonMap>[];
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
    int left() => deadline.difference(DateTime.now()).inMilliseconds;
    // Waiting for the page never runs past the time limit either.
    Future<void> settleIn([int cap = 8000]) => settle(s, maxMs: left().clamp(0, cap));
    await _open(s, url, fast: fast, timeoutMs: timeoutMs);
    await settleIn();
    if (visible) await page.show(s);
    try {
      for (final c in commands) {
        Never failAt(String message) => throw BrowserException('line ${c.line}: $message');
        // Out of time, or the caller already gave up: do nothing more on the page.
        if (progress?.stopped == true || left() <= 0) {
          throw BrowserException('the steps did not finish within ${(timeoutMs / 1000).round()} s');
        }
        switch (c.verb) {
          case 'open':
            await _open(s, c.target, fast: fast, timeoutMs: timeoutMs);
            await settleIn();
          case 'click':
            await ready(c.target);
            progress?.acted = true;
            _check(await _act(s, 'fd.click(${_js(c.target)})'), failAt);
            await settleIn(_actionSettleMs);
          case 'type':
            await ready(c.target);
            progress?.acted = true;
            _check(await _act(s, 'fd.type(${_js(c.target)}, ${_js(c.text)})'), failAt);
          case 'press':
            progress?.acted = true;
            _check(await _act(s, 'fd.press(${_js(c.target)})'), failAt);
            await settleIn(_actionSettleMs);
          case 'wait':
            if (c.target.isEmpty) {
              final ms = (double.parse(c.text) * 1000).round();
              if (ms >= left()) {
                // It would run past the time limit: wait out what is left, then stop.
                await Future<void>.delayed(Duration(milliseconds: left().clamp(0, ms)));
                throw BrowserException('the steps did not finish within ${(timeoutMs / 1000).round()} s');
              }
              await Future<void>.delayed(Duration(milliseconds: ms));
            } else {
              await waitFor(s, c.target, timeoutMs: left(), failAt: failAt);
            }
          case 'extract':
            await appear(c.target);
            final r = _check(await _act(s, 'fd.extract(${_js(c.target)}, ${c.all}, ${_js(c.attr)})'), failAt);
            data[c.name] = r['value'];
          case 'scroll':
            if (c.target.isNotEmpty) await appear(c.target);
            _check(await _act(s, 'fd.scroll(${_js(c.target)})'), failAt);
          case 'back':
            await page.back(s);
            await settleIn(_actionSettleMs);
          case 'screenshot':
            final name = c.name.isEmpty ? 'page' : c.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
            // The counter keeps two screenshots taken within one millisecond apart.
            final path = 'browser/${DateTime.now().millisecondsSinceEpoch}-${_shots++}-$name.png';
            final r = await page.screenshot(s, path);
            if (r['error'] case final String error) failAt(error);
            screenshots.add(await saveScreenshot(path));
          case 'js':
            final r = _check(await _act(s, 'return {ok: true, value: (function(){ ${c.text} })()}'), failAt);
            data[c.name.isEmpty ? 'js' : c.name] = r['value'];
          case 'show':
            await page.show(s);
          case 'hide':
            await page.hide(s);
        }
      }
      final state = await _state(s);
      return {
        'url': asString(state['url']),
        'title': asString(state['title']),
        'data': data,
        'screenshots': screenshots,
      };
    } on BrowserException catch (e) {
      // A step failing on a login page means the saved login has ended, not that the steps are wrong.
      if (!isRetryable(e.message) && !_isLoginUrl(url) && await _loginWall(s)) {
        final st = await _state(s).catchError((Object _) => <String, Object?>{});
        throw BrowserException('${_loggedOut(asString(st['url'], url))} (${e.message})');
      }
      if (isRetryable(e.message)) rethrow;
      // Say what the page showed: a block screen, an error banner or a pop-up names the
      // real cause on any site, where the step's own error only says what it missed.
      throw BrowserException('${e.message}${await glance(s)}');
    } finally {
      // Leave it up: a run of a few quick steps would otherwise flash on and off screen
      // before the person sees anything, and on a failure they can see where it stopped.
      // Also sent when this run was hidden: a window left open by an earlier run may
      // have shown it. A failure here must not hide the run's own result or error.
      try {
        await page.finished(s);
      } on Object catch (_) {}
    }
  }

  /// What the page in [s] shows now, for an error message: its title and address, the
  /// last pop-up it raised, and the start of its visible text. Empty if it can't be read.
  Future<String> glance(String s) async {
    try {
      final g = await _act(s, 'fd.glance()').timeout(const Duration(seconds: 3));
      final title = asString(g['title']).trim();
      final where = asString(g['url']);
      final text = asString(g['text']).trim();
      final dialog = asString(g['dialog']).trim();
      if (where.isEmpty && title.isEmpty) return '';
      return [
        '. The page was ${title.isEmpty ? where : '“$title” ($where)'}',
        if (dialog.isNotEmpty) ', it showed a pop-up saying “$dialog”',
        if (text.isNotEmpty) ' and it says: “$text”',
      ].join();
    } on Object catch (_) {
      return '';
    }
  }

  Future<bool> _loginWall(String s) async {
    try {
      return (await _act(s, 'fd.loginWall()'))['value'] == true;
    } on BrowserException {
      return false;
    }
  }

  static bool _isLoginUrl(String url) =>
      RegExp(r'/(login|log-in|signin|sign-in|sign_in|auth)(/|$|\?)', caseSensitive: false).hasMatch(url);

  static String _loggedOut(String url) {
    final host = Uri.tryParse(url)?.host ?? url;
    return 'logged out of $host: the page asks to log in. Log in again in Settings → Browser logins, '
        'then run it again';
  }

  Future<void> _open(String s, String url, {required bool fast, required int timeoutMs}) async {
    final JsonMap r;
    try {
      r = await page.open(s, url, fast: fast, timeoutMs: timeoutMs).timeout(Duration(milliseconds: timeoutMs + 5000));
    } on TimeoutException {
      throw const BrowserException('the page stopped answering');
    }
    if (r['error'] case final String error) throw BrowserException(error);
  }

  JsonMap _check(JsonMap r, Never Function(String) failAt) {
    if (r['error'] case final String error) failAt(error);
    return r;
  }

  // ---------------------------------------------------------------- script

  static const _verbs = {
    'open',
    'click',
    'type',
    'press',
    'wait',
    'extract',
    'scroll',
    'back',
    'screenshot',
    'js',
    'show',
    'hide',
  };

  /// The script's commands; blank lines and `#` comments are skipped. Throws on the first bad line.
  static List<BrowserCommand> parse(String script) {
    final out = <BrowserCommand>[];
    final lines = const LineSplitter().convert(script);
    for (var i = 0; i < lines.length; i++) {
      final n = i + 1;
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final space = line.indexOf(RegExp(r'\s'));
      final verb = (space < 0 ? line : line.substring(0, space)).toLowerCase();
      final rest = space < 0 ? '' : line.substring(space).trim();
      Never bad(String message) => throw BrowserException('line $n: $message');
      if (!_verbs.contains(verb)) bad('unknown step “$verb” (use ${_verbs.join(', ')})');
      switch (verb) {
        case 'open':
          if (!RegExp(r'^https?://').hasMatch(rest)) bad('open needs a URL starting with http:// or https://');
          out.add(BrowserCommand(n, verb, target: rest));
        case 'click' || 'scroll':
          if (verb == 'click' && rest.isEmpty) bad('click what? e.g. click text="Sign in" or click #submit');
          out.add(BrowserCommand(n, verb, target: rest));
        case 'type':
          final (target, text) = _target(rest);
          if (target.isEmpty) bad('type where? e.g. type #email you@example.com');
          out.add(BrowserCommand(n, verb, target: target, text: text));
        case 'press':
          out.add(BrowserCommand(n, verb, target: rest.isEmpty ? 'Enter' : rest));
        case 'wait':
          if (rest.toLowerCase().startsWith('for ')) {
            out.add(BrowserCommand(n, verb, target: rest.substring(4).trim()));
          } else {
            final seconds = double.tryParse(rest.replaceAll(RegExp(r's$'), ''));
            if (seconds == null || seconds < 0 || seconds > 300) {
              bad('wait needs seconds (e.g. wait 2) or “wait for <element>”');
            }
            out.add(BrowserCommand(n, verb, text: '$seconds'));
          }
        case 'extract':
          var words = rest;
          final all = words.toLowerCase().startsWith('all ');
          if (all) words = words.substring(4).trim();
          final space = words.indexOf(RegExp(r'\s'));
          if (space < 0) bad('extract needs a name and a selector, e.g. extract price .price');
          final name = words.substring(0, space);
          var selector = words.substring(space).trim();
          var attr = '';
          final at = RegExp(r'\s@([A-Za-z_:][-A-Za-z0-9_:.]*)$').firstMatch(selector);
          if (at != null) {
            attr = at[1]!;
            selector = selector.substring(0, at.start).trim();
          }
          out.add(BrowserCommand(n, verb, name: name, target: selector, all: all, attr: attr));
        case 'back' || 'show' || 'hide':
          out.add(BrowserCommand(n, verb));
        case 'screenshot':
          out.add(BrowserCommand(n, verb, name: rest));
        case 'js':
          if (rest.isEmpty) bad('js needs code, e.g. js return document.title');
          // Only a real `return` statement counts: `.returns` or `return-policy` in a selector do not.
          final returns = RegExp(r'(^|[;{}\s])return([\s;(]|$)').hasMatch(rest);
          out.add(BrowserCommand(n, verb, text: returns ? rest : 'return ($rest)'));
      }
    }
    return out;
  }

  /// The first word of [rest] as a target (`"quoted words"` and `text="…"` stay whole), and the rest.
  static (String, String) _target(String rest) {
    // text="…" may hold escaped quotes (text="Say \"hi\""), as page targets do.
    final m = RegExp(r'^(text="(?:[^"\\]|\\.)*"|"[^"]*"|\S+)\s*(.*)$', dotAll: true).firstMatch(rest);
    if (m == null) return ('', '');
    var target = m[1]!;
    if (target.startsWith('"') && target.endsWith('"') && target.length >= 2) {
      target = target.substring(1, target.length - 1);
    }
    return (target, m[2]!);
  }

  // ---------------------------------------------------------------- waiting, fast

  /// Waits until the page is usable: its HTML is parsed, its fetch/XHR calls are
  /// done and its content stopped changing for [quiet] (or [maxMs] passed).
  ///
  /// It does not wait for images, ads or trackers (`readyState == 'complete'`), and
  /// network calls still open after [_netGraceMs] (long polling, live feeds) are ignored.
  /// After a click the cap is short: the next step waits for its own element anyway.
  Future<void> settle(String s, {int maxMs = 8000}) async {
    final start = DateTime.now();
    var lastCount = -1;
    var stableSince = DateTime.now();
    var lastUrl = '';
    while (true) {
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      if (elapsed >= maxMs) return;
      final st = await _state(s);
      final count = asInt(st['mutations']);
      final url = asString(st['url']);
      if (count != lastCount || url != lastUrl) {
        lastCount = count;
        lastUrl = url;
        stableSince = DateTime.now();
      }
      final parsed = st['ready'] != 'loading';
      final idle = asInt(st['net']) == 0 || elapsed >= _netGraceMs;
      if (parsed && idle && DateTime.now().difference(stableSince) >= quiet) return;
      await Future<void>.delayed(poll);
    }
  }

  static const _netGraceMs = 1500;

  /// The longest to wait after a click, key press or going back.
  static const _actionSettleMs = 3000;

  Future<void> waitFor(
    String s,
    String target, {
    required int timeoutMs,
    required Never Function(String) failAt,
  }) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start).inMilliseconds < timeoutMs) {
      final r = await _act(s, 'fd.present(${_js(target)})');
      if (r['value'] == true) return;
      await Future<void>.delayed(poll);
    }
    failAt('“$target” did not appear');
  }

  /// Waits up to [maxMs] for [target] to be on the page; the step itself reports it if it never is.
  Future<void> _appear(String s, String target, int maxMs, {String check = 'present'}) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start).inMilliseconds < maxMs) {
      final r = await _act(s, 'fd.$check(${_js(target)})');
      if (r['value'] == true || r['error'] != null) return;
      await Future<void>.delayed(poll * 2);
    }
  }

  Future<JsonMap> _state(String s) => _act(s, 'fd.state()');

  /// Runs [body] with the `fd` helpers; its returned object.
  ///
  /// The helpers (several KB) are only sent when the page does not have them yet,
  /// so the many small polls stay cheap.
  Future<JsonMap> _act(String s, String body) async {
    final code = body.startsWith('return') ? body : 'return $body';
    final call = 'const fd = window.__fd; try { $code; } catch (e) { return {error: String(e && e.message || e)}; }';
    final r = await _eval(s, '(function(){if (!window.__fd) return {__noHelpers: true};\n$call})()');
    if (r['__noHelpers'] != true) return r;
    return _eval(s, '(function(){$_helpers\n$call})()');
  }

  Future<JsonMap> _eval(String s, String js) async {
    final String? raw;
    try {
      raw = await page.eval(s, js).timeout(callTimeout);
    } on TimeoutException {
      throw const BrowserException('the page stopped answering');
    }
    if (raw == null || raw == 'null') throw const BrowserException('the page is not open');
    final decoded = jsonDecode(raw);
    if (decoded is String) {
      // Some WebViews hand back the JSON text of the JSON text.
      return asMap(jsonDecode(decoded));
    }
    return asMap(decoded);
  }

  static String _js(String s) => jsonEncode(s);

  /// Page-side helpers, installed once per page.
  static const _helpers = r'''
if (!window.__fd) {
  const label = (e) => ((e.getAttribute && (e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('alt'))) || e.innerText || e.value || (e.getAttribute && e.getAttribute('name')) || '').trim().replace(/\s+/g, ' ').slice(0, 80);
  const visible = (e) => { const r = e.getBoundingClientRect(); const st = getComputedStyle(e); return r.width > 0 && r.height > 0 && st.visibility !== 'hidden' && st.display !== 'none'; };
  const clickable = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=switch],[onclick],[contenteditable=true]';
  // Open shadow roots (web components), searched only when the page itself has no match.
  const shadowRoots = () => {
    const out = [];
    const walk = (root) => { for (const el of root.querySelectorAll('*')) if (el.shadowRoot) { out.push(el.shadowRoot); walk(el.shadowRoot); } };
    walk(document);
    return out;
  };
  // Documents of embedded frames from the same site (login forms, editors, cookie
  // banners often live there). Frames from other sites cannot be reached by any page.
  const frameDocs = () => {
    const out = [];
    const walk = (doc) => { for (const f of doc.querySelectorAll('iframe,frame')) { try { const d = f.contentDocument; if (d && d.body) { out.push(d); walk(d); } } catch (e) {} } };
    walk(document);
    return out;
  };
  // Where to look, in order: the page, then its shadow roots, then its frames.
  const scopes = () => [document, ...shadowRoots(), ...frameDocs()];
  const queryAll = (sel) => {
    let els;
    try { els = [...document.querySelectorAll(sel)]; } catch (e) { throw new Error('not a valid selector: ' + sel); }
    if (els.length) return els;
    for (const r of scopes().slice(1)) els.push(...r.querySelectorAll(sel));
    return els;
  };
  const byText = (root, want) => {
    const els = [...root.querySelectorAll(clickable)].filter(visible);
    return els.find((e) => label(e).toLowerCase() === want) || els.find((e) => label(e).toLowerCase().includes(want))
      || [...root.querySelectorAll('*')].find((e) => e.children.length === 0 && visible(e) && (e.innerText || e.textContent || '').trim().toLowerCase().includes(want));
  };
  const find = (t) => {
    if (/^\d+$/.test(t)) return document.querySelector('[data-fd-id="' + t + '"]');
    if (t.startsWith('text=')) {
      const want = t.slice(5).replace(/^"|"$/g, '').replace(/\\"/g, '"').trim().toLowerCase();
      for (const root of scopes()) { const e = byText(root, want); if (e) return e; }
      return null;
    }
    // Pages often keep hidden copies (mobile and desktop menus): use the one that is showing.
    const els = queryAll(t);
    return els.find(visible) || els[0] || null;
  };
  // Ids and names that frameworks make up per visit (mui-48213, ember392, :r1:, input-3f9a2c).
  const generated = (v) => /\d{3,}|(?=[0-9a-f]*\d)[0-9a-f]{6,}|^(ember|mui|radix|react|headlessui|rc[-_]|:r)/i.test(v);
  const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch (x) { return false; } };
  // A CSS path from the nearest ancestor with a lasting id (or body): always points at this one element.
  const path = (e) => {
    const parts = [];
    let n = e;
    for (; n && n.nodeType === 1 && n !== document.body && n !== document.documentElement; n = n.parentElement) {
      if (n !== e && n.id && /^[A-Za-z][\w-]*$/.test(n.id) && !generated(n.id) && unique('#' + n.id)) { parts.unshift('#' + n.id); break; }
      const tag = n.tagName.toLowerCase();
      const same = n.parentElement ? [...n.parentElement.children].filter((c) => c.tagName === n.tagName) : [];
      parts.unshift(same.length > 1 ? tag + ':nth-of-type(' + (same.indexOf(n) + 1) + ')' : tag);
    }
    if (!n || n === document.body || n === document.documentElement) parts.unshift('body');
    return parts.join(' > ');
  };
  // A target that still finds this element, and only this one, on the next visit
  // (numbers are only for this view). Never a bare tag: that would hit the first of its kind.
  const stable = (e) => {
    const q = (v) => String(v).replace(/"/g, '\\"');
    const tag = e.tagName.toLowerCase();
    if (e.id && /^[A-Za-z][\w-]*$/.test(e.id) && !generated(e.id) && unique('#' + e.id)) return '#' + e.id;
    for (const a of ['data-testid', 'name', 'aria-label', 'placeholder']) {
      const v = e.getAttribute(a);
      if (!v || ((a === 'name' || a === 'data-testid') && generated(v))) continue;
      if (unique(tag + '[' + a + '="' + q(v) + '"]')) return tag + '[' + a + '="' + q(v) + '"]';
    }
    const l = label(e);
    if (l) {
      const same = [...document.querySelectorAll(clickable)].filter((x) => visible(x) && label(x).toLowerCase() === l.toLowerCase());
      if (same.length === 1 && same[0] === e) return 'text="' + q(l) + '"';
    }
    return path(e);
  };
  // What a real tap sends: pointer and mouse presses first (many menus and React
  // widgets only listen to those), then the click.
  const tap = (e) => {
    const r = e.getBoundingClientRect();
    const o = {bubbles: true, cancelable: true, composed: true, view: window, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0};
    try { e.dispatchEvent(new PointerEvent('pointerdown', Object.assign({pointerType: 'touch', isPrimary: true}, o))); } catch (x) {}
    e.dispatchEvent(new MouseEvent('mousedown', o));
    e.focus && e.focus();
    try { e.dispatchEvent(new PointerEvent('pointerup', Object.assign({pointerType: 'touch', isPrimary: true}, o))); } catch (x) {}
    e.dispatchEvent(new MouseEvent('mouseup', o));
    e.click();
  };
  const need = (t) => { const e = find(t); if (!e) throw new Error('nothing on the page matches ' + t); return e; };
  window.__fdMutations = 0;
  // Only added and removed content counts: style and attribute churn (animations,
  // carousels, timers) would otherwise keep the page "busy" forever.
  try { new MutationObserver((m) => { window.__fdMutations += m.length; }).observe(document, {subtree: true, childList: true}); } catch (e) {}
  window.__fd = {
    state: () => ({ready: document.readyState, url: location.href, title: document.title, mutations: window.__fdMutations, net: window.__fdNet || 0}),
    // Whether there is anything to press or fill in yet (also in same-site frames).
    content: () => ({value: scopes().some((r) => [...r.querySelectorAll(clickable)].some(visible))}),
    // What a person would see first: for error messages.
    glance: () => ({url: location.href, title: document.title, dialog: window.__fdDialog || '',
      text: (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').trim().slice(0, 240)}),
    loginWall: () => ({value: [...document.querySelectorAll('input[type=password]')].some(visible)
      || /\/(login|log-in|signin|sign-in|sign_in|auth)(\/|$|\?)/i.test(location.pathname)}),
    present: (t) => ({value: (() => { const e = find(t); return !!e && visible(e); })()}),
    // Showing and usable: buttons that turn on later (once a form is filled) are waited for.
    actionable: (t) => ({value: (() => { const e = find(t); return !!e && visible(e) && !e.disabled && e.getAttribute('aria-disabled') !== 'true'; })()}),
    click: (t) => { const e = need(t); e.scrollIntoView({block: 'center'}); tap(e); return {ok: true}; },
    type: (t, text) => {
      const e = need(t); e.scrollIntoView({block: 'center'}); e.focus && e.focus();
      // Rich editors (Telegram, WhatsApp, Slack) only notice text that arrives like typing:
      // replace the content with insertText, and set it directly only if that is refused.
      if (e.isContentEditable) {
        const sel = window.getSelection(); const range = document.createRange();
        range.selectNodeContents(e); sel.removeAllRanges(); sel.addRange(range);
        let typed = false;
        try { typed = document.execCommand('insertText', false, text); } catch (x) {}
        if (!typed) { e.textContent = text; e.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: text})); }
        return {ok: true};
      } else {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e), 'value');
        if (setter && setter.set) setter.set.call(e, text); else e.value = text;
      }
      e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));
      return {ok: true};
    },
    press: (key) => {
      const e = document.activeElement || document.body;
      // Many sites still read keyCode/which (13 for Enter), which synthetic events leave at 0.
      const codes = {Enter: 13, Tab: 9, Escape: 27, Backspace: 8, ArrowDown: 40, ArrowUp: 38, ArrowLeft: 37, ArrowRight: 39, ' ': 32};
      const keyCode = codes[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
      for (const type of ['keydown', 'keypress', 'keyup']) {
        const ev = new KeyboardEvent(type, {key, code: key === ' ' ? 'Space' : key, bubbles: true, cancelable: true, composed: true});
        try { Object.defineProperty(ev, 'keyCode', {get: () => keyCode}); Object.defineProperty(ev, 'which', {get: () => keyCode}); } catch (x) {}
        e.dispatchEvent(ev);
      }
      if (key === 'Enter' && e.form) { e.form.requestSubmit ? e.form.requestSubmit() : e.form.submit(); }
      return {ok: true};
    },
    scroll: (t) => { if (t) need(t).scrollIntoView({block: 'center'}); else window.scrollBy(0, innerHeight * 0.9); return {ok: true}; },
    extract: (sel, all, attr) => {
      const found = queryAll(sel);
      const els = all ? found : [found.find(visible) || found[0]].filter(Boolean);
      if (!all && els.length === 0) throw new Error('nothing on the page matches ' + sel);
      const read = (e) => attr ? (attr === 'href' && e.href ? e.href : attr === 'src' && e.src ? e.src : e.getAttribute(attr)) : (e.innerText || e.value || e.textContent || '').trim();
      return {value: all ? els.map(read) : read(els[0])};
    },
    snapshot: (maxText) => {
      document.querySelectorAll('[data-fd-id]').forEach((e) => e.removeAttribute('data-fd-id'));
      const lines = []; let n = 0;
      for (const e of document.querySelectorAll(clickable)) {
        if (n >= 80) break;
        if (!visible(e)) continue;
        n++; e.setAttribute('data-fd-id', String(n));
        const tag = e.tagName.toLowerCase();
        const kind = tag === 'input' ? 'input ' + (e.type || 'text') : tag === 'a' ? 'link' : (e.getAttribute('role') || tag);
        const value = (tag === 'input' || tag === 'textarea' || tag === 'select') && e.type !== 'password' ? ' value="' + String(e.value || '').slice(0, 40) + '"' : '';
        lines.push('[' + n + '] ' + kind + ' "' + label(e) + '"' + value + ' · target: ' + stable(e));
      }
      const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').trim();
      return {url: location.href, title: document.title, elements: lines, text: text.slice(0, maxText), more: text.length > maxText};
    },
  };
}''';

  // ---------------------------------------------------------------- AI Agent tool

  /// One AI Agent browser action (`{action, url, target, text}`), limited to [sites]
  /// (comma separated; empty = any). Returns the page as the AI sees it now.
  Future<String> agent(JsonMap input, String sites, {String? session}) async {
    final s = session ?? agentSession;
    final allowed = sites.split(',').map((x) => x.trim().toLowerCase()).where((x) => x.isNotEmpty).toList();
    bool ok(String url) {
      if (allowed.isEmpty) return true;
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      return allowed.any((site) {
        final bare = site.replaceAll(RegExp(r'^https?://'), '').split('/').first;
        return host == bare || host.endsWith('.$bare');
      });
    }

    final action = asString(input['action']);
    final target = asString(input['target']);
    final text = asString(input['text']);
    Future<JsonMap> act(String js) async {
      final r = await _act(s, js);
      // With what the page shows, so the AI can see a block screen or pop-up for itself.
      if (r['error'] case final String error) throw BrowserException('$error${await glance(s)}');
      return r;
    }

    switch (action) {
      case 'open':
        final url = asString(input['url']);
        if (!RegExp(r'^https?://').hasMatch(url)) throw const BrowserException('open needs a full URL');
        if (!ok(url)) throw BrowserException('this tool may only visit: ${allowed.join(', ')}');
        await _open(s, url, fast: true, timeoutMs: 30000);
        await settle(s, maxMs: 4000);
      case 'read':
        break;
      case 'click':
        await act('fd.click(${_js(target)})');
        await settle(s, maxMs: _actionSettleMs);
      case 'type':
        await act('fd.type(${_js(target)}, ${_js(text)})');
      case 'press':
        await act('fd.press(${_js(text.isEmpty ? 'Enter' : text)})');
        await settle(s, maxMs: _actionSettleMs);
      case 'scroll':
        await act('fd.scroll(${_js(target)})');
      case 'back':
        await page.back(s);
        await settle(s, maxMs: _actionSettleMs);
      default:
        throw BrowserException('unknown action “$action”');
    }
    // Big web apps (mail, chat, dashboards) draw their buttons well after the page
    // "loads": wait for something to use before reading it, briefly after an action.
    if (action != 'read') await _waitForContent(s, action == 'open' ? 12000 : 3000);
    final view = await act('fd.snapshot(4000)');
    final url = asString(view['url']);
    if (!ok(url)) {
      await page.back(s);
      await settle(s);
      throw BrowserException('that led to $url, which this tool may not visit; went back');
    }
    final seen = pageView(view);
    if (asList(view['elements']).isNotEmpty) return seen;
    // Nothing to press or fill in: a picture of the page says what words can't.
    try {
      final path = 'browser/assistant-${DateTime.now().millisecondsSinceEpoch}-${_shots++}.png';
      final r = await page.screenshot(s, path);
      if (r['error'] == null) {
        await saveScreenshot(path);
        return '$seen\nNo buttons or fields were found. A screenshot of the page is at /root/files/$path';
      }
    } on Object catch (_) {}
    return seen;
  }

  /// Waits up to [maxMs] for the page to show a button, link or field.
  Future<void> _waitForContent(String s, int maxMs) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start).inMilliseconds < maxMs) {
      try {
        if ((await _act(s, 'fd.content()'))['value'] == true) return;
      } on BrowserException {
        return;
      }
      await Future<void>.delayed(poll * 4);
    }
  }

  /// What the AI reads: title, address, numbered elements and the page text.
  static String pageView(JsonMap view) {
    final elements = asList(view['elements']).map(asString).toList();
    return [
      'Page: ${asString(view['title'])}',
      'URL: ${asString(view['url'])}',
      if (elements.isNotEmpty) ...['Elements (use the number as target):', ...elements],
      'Text:',
      asString(view['text']),
      if (view['more'] == true) '… (more below; scroll to read on)',
    ].join('\n');
  }
}

/// What a run has done so far: after a click or typing it is not safe to start over.
class BrowserProgress {
  bool acted = false;

  /// Set when the caller gave up on the run (it timed out): the script stops before its
  /// next step, so a run reported as failed never goes on clicking in the background.
  bool stopped = false;
}
