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
  });

  final BrowserPage page;

  /// Turns a screenshot's path in FlowDroid's folder into a file reference `{path, name, mimeType, size}`.
  final Future<JsonMap> Function(String path) saveScreenshot;
  final Duration poll;
  final Duration quiet;

  /// The session Browser steps share (kept warm between runs); one run at a time.
  static const runSession = 'run';
  static const agentSession = 'agent';
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
            await runScript(
              asString(run['url']),
              asString(run['steps']),
              visible: effect['visible'] == true,
              fast: effect['fast'] == true,
              timeoutMs: timeoutMs,
            ).timeout(Duration(milliseconds: timeoutMs)),
          );
        } on TimeoutException {
          results.add({'error': 'the steps did not finish within ${(timeoutMs / 1000).round()} s'});
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

  /// Opens [url], runs each line of [script], and returns where it ended up and what it extracted.
  Future<JsonMap> runScript(
    String url,
    String script, {
    bool visible = false,
    bool fast = true,
    int timeoutMs = 60000,
  }) async {
    final commands = parse(script);
    const s = runSession;
    final data = <String, Object?>{};
    final screenshots = <JsonMap>[];
    await _open(s, url, fast: fast, timeoutMs: timeoutMs);
    var shown = false;
    if (visible) shown = !(await page.show(s)).containsKey('error');
    try {
      for (final c in commands) {
        Never failAt(String message) => throw BrowserException('line ${c.line}: $message');
        switch (c.verb) {
          case 'open':
            await _open(s, c.target, fast: fast, timeoutMs: timeoutMs);
          case 'click':
            _check(await _act(s, 'fd.click(${_js(c.target)})'), failAt);
            await settle(s);
          case 'type':
            _check(await _act(s, 'fd.type(${_js(c.target)}, ${_js(c.text)})'), failAt);
          case 'press':
            _check(await _act(s, 'fd.press(${_js(c.target)})'), failAt);
            await settle(s);
          case 'wait':
            if (c.target.isEmpty) {
              await Future<void>.delayed(Duration(milliseconds: (double.parse(c.text) * 1000).round()));
            } else {
              await waitFor(s, c.target, timeoutMs: timeoutMs, failAt: failAt);
            }
          case 'extract':
            final r = _check(await _act(s, 'fd.extract(${_js(c.target)}, ${c.all}, ${_js(c.attr)})'), failAt);
            data[c.name] = r['value'];
          case 'scroll':
            _check(await _act(s, 'fd.scroll(${_js(c.target)})'), failAt);
          case 'back':
            await page.back(s);
            await settle(s);
          case 'screenshot':
            final name = c.name.isEmpty ? 'page' : c.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
            final path = 'browser/${DateTime.now().millisecondsSinceEpoch}-$name.png';
            final r = await page.screenshot(s, path);
            if (r['error'] case final String error) failAt(error);
            screenshots.add(await saveScreenshot(path));
          case 'js':
            final r = _check(await _act(s, 'return {ok: true, value: (function(){ ${c.text} })()}'), failAt);
            data[c.name.isEmpty ? 'js' : c.name] = r['value'];
          case 'show':
            shown = !(await page.show(s)).containsKey('error');
          case 'hide':
            await page.hide(s);
            shown = false;
        }
      }
      final state = await _state(s);
      return {
        'url': asString(state['url']),
        'title': asString(state['title']),
        'data': data,
        'screenshots': screenshots,
      };
    } finally {
      if (shown) await page.hide(s);
    }
  }

  Future<void> _open(String s, String url, {required bool fast, required int timeoutMs}) async {
    final r = await page.open(s, url, fast: fast, timeoutMs: timeoutMs);
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
          out.add(BrowserCommand(n, verb, text: rest.contains('return') ? rest : 'return ($rest)'));
      }
    }
    return out;
  }

  /// The first word of [rest] as a target (`"quoted words"` and `text="…"` stay whole), and the rest.
  static (String, String) _target(String rest) {
    final m = RegExp(r'^(text="[^"]*"|"[^"]*"|\S+)\s*(.*)$', dotAll: true).firstMatch(rest);
    if (m == null) return ('', '');
    var target = m[1]!;
    if (target.startsWith('"') && target.endsWith('"') && target.length >= 2) {
      target = target.substring(1, target.length - 1);
    }
    return (target, m[2]!);
  }

  // ---------------------------------------------------------------- waiting, fast

  /// Waits until the page has finished loading and stopped changing (or [maxMs] passed).
  Future<void> settle(String s, {int maxMs = 8000}) async {
    final start = DateTime.now();
    var lastCount = -1;
    var stableSince = DateTime.now();
    var lastUrl = '';
    while (DateTime.now().difference(start).inMilliseconds < maxMs) {
      final st = await _state(s);
      final count = asInt(st['mutations']);
      final url = asString(st['url']);
      if (count != lastCount || url != lastUrl) {
        lastCount = count;
        lastUrl = url;
        stableSince = DateTime.now();
      }
      final loaded = st['ready'] == 'complete';
      if (loaded && DateTime.now().difference(stableSince) >= quiet) return;
      await Future<void>.delayed(poll);
    }
  }

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

  Future<JsonMap> _state(String s) => _act(s, 'fd.state()');

  /// Runs [body] with the `fd` helpers; its returned object.
  Future<JsonMap> _act(String s, String body) async {
    final code = body.startsWith('return') ? body : 'return $body';
    final raw = await page.eval(
      s,
      '(function(){$_helpers\nconst fd = window.__fd; try { $code; } catch (e) { return {error: String(e && e.message || e)}; }})()',
    );
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
  const clickable = 'a[href],button,input,select,textarea,summary,label,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[onclick],[contenteditable=true]';
  const find = (t) => {
    if (/^\d+$/.test(t)) return document.querySelector('[data-fd-id="' + t + '"]');
    if (t.startsWith('text=')) {
      const want = t.slice(5).replace(/^"|"$/g, '').trim().toLowerCase();
      const els = [...document.querySelectorAll(clickable)].filter(visible);
      return els.find((e) => label(e).toLowerCase() === want) || els.find((e) => label(e).toLowerCase().includes(want))
        || [...document.querySelectorAll('body *')].find((e) => e.children.length === 0 && visible(e) && (e.innerText || '').trim().toLowerCase().includes(want));
    }
    try { return document.querySelector(t); } catch (e) { throw new Error('not a valid selector: ' + t); }
  };
  const need = (t) => { const e = find(t); if (!e) throw new Error('nothing on the page matches ' + t); return e; };
  window.__fdMutations = 0;
  try { new MutationObserver((m) => { window.__fdMutations += m.length; }).observe(document, {subtree: true, childList: true, attributes: true, characterData: true}); } catch (e) {}
  window.__fd = {
    state: () => ({ready: document.readyState, url: location.href, title: document.title, mutations: window.__fdMutations}),
    present: (t) => ({value: (() => { const e = find(t); return !!e && visible(e); })()}),
    click: (t) => { const e = need(t); e.scrollIntoView({block: 'center'}); e.focus && e.focus(); e.click(); return {ok: true}; },
    type: (t, text) => {
      const e = need(t); e.scrollIntoView({block: 'center'}); e.focus && e.focus();
      if (e.isContentEditable) { e.textContent = text; } else {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e), 'value');
        if (setter && setter.set) setter.set.call(e, text); else e.value = text;
      }
      e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));
      return {ok: true};
    },
    press: (key) => {
      const e = document.activeElement || document.body;
      for (const type of ['keydown', 'keypress', 'keyup']) e.dispatchEvent(new KeyboardEvent(type, {key, code: key, bubbles: true}));
      if (key === 'Enter' && e.form) { e.form.requestSubmit ? e.form.requestSubmit() : e.form.submit(); }
      return {ok: true};
    },
    scroll: (t) => { if (t) need(t).scrollIntoView({block: 'center'}); else window.scrollBy(0, innerHeight * 0.9); return {ok: true}; },
    extract: (sel, all, attr) => {
      let els;
      try { els = all ? [...document.querySelectorAll(sel)] : [document.querySelector(sel)].filter(Boolean); } catch (e) { throw new Error('not a valid selector: ' + sel); }
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
        lines.push('[' + n + '] ' + kind + ' "' + label(e) + '"' + value);
      }
      const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').trim();
      return {url: location.href, title: document.title, elements: lines, text: text.slice(0, maxText), more: text.length > maxText};
    },
  };
}''';

  // ---------------------------------------------------------------- AI Agent tool

  /// One AI Agent browser action (`{action, url, target, text}`), limited to [sites]
  /// (comma separated; empty = any). Returns the page as the AI sees it now.
  Future<String> agent(JsonMap input, String sites) async {
    const s = agentSession;
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
      if (r['error'] case final String error) throw BrowserException(error);
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
        await settle(s);
      case 'type':
        await act('fd.type(${_js(target)}, ${_js(text)})');
      case 'press':
        await act('fd.press(${_js(text.isEmpty ? 'Enter' : text)})');
        await settle(s);
      case 'scroll':
        await act('fd.scroll(${_js(target)})');
      case 'back':
        await page.back(s);
        await settle(s);
      default:
        throw BrowserException('unknown action “$action”');
    }
    final view = await act('fd.snapshot(4000)');
    final url = asString(view['url']);
    if (!ok(url)) {
      await page.back(s);
      await settle(s);
      throw BrowserException('that led to $url, which this tool may not visit; went back');
    }
    return pageView(view);
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
