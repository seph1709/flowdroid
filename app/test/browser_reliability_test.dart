import 'dart:convert';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/runtime/browser/browser_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page that can crash, load content late, and show a login form.
class _FlakyPage implements BrowserPage {
  /// Errors the next opens return, in order.
  final openErrors = <String>[];

  /// `fd.present` answers false this many times first (content still loading).
  int lateBy = 0;
  bool loginForm = false;
  bool clickCrashes = false;
  int opens = 0;
  final clicks = <String>[];

  static String _call(String js) =>
      RegExp(r'const fd = window\.__fd; try \{ return (.*?); \} catch', dotAll: true).firstMatch(js)![1]!;

  @override
  Future<JsonMap> open(String session, String url, {required bool fast, required int timeoutMs}) async {
    opens++;
    if (openErrors.isNotEmpty) return {'error': openErrors.removeAt(0)};
    return {'url': url, 'title': 'Site'};
  }

  @override
  Future<String?> eval(String session, String js) async {
    final call = _call(js);
    if (call.startsWith('fd.state()')) {
      return jsonEncode({'ready': 'complete', 'url': 'https://site.example/login', 'title': 'Site', 'mutations': 0});
    }
    if (call.startsWith('fd.present')) return jsonEncode({'value': lateBy-- <= 0});
    if (call.startsWith('fd.loginWall')) return jsonEncode({'value': loginForm});
    if (call.startsWith('fd.click')) {
      clicks.add(call);
      if (clickCrashes) return null; // the renderer died
      if (lateBy >= 0) return jsonEncode({'error': 'nothing on the page matches #go'});
      return jsonEncode({'ok': true});
    }
    if (call.startsWith('fd.extract')) {
      if (lateBy >= 0) return jsonEncode({'error': 'nothing on the page matches h1'});
      return jsonEncode({'value': 'Hello'});
    }
    return jsonEncode({'ok': true});
  }

  @override
  Future<bool> back(String session) async => true;

  @override
  Future<JsonMap> screenshot(String session, String path) async => {};

  @override
  Future<JsonMap> show(String session) async => {};

  @override
  Future<void> hide(String session) async {}
}

void main() {
  late _FlakyPage page;
  late BrowserDriver driver;

  setUp(() {
    page = _FlakyPage();
    driver = BrowserDriver(
      page,
      saveScreenshot: (path) async => {'path': path},
      poll: const Duration(milliseconds: 1),
      quiet: const Duration(milliseconds: 2),
      elementWaitMs: 30,
    );
  });

  Future<JsonMap> run(String steps) async =>
      asMapList((await driver({
        'runs': [
          {'url': 'https://site.example/', 'steps': steps},
        ],
        'timeoutMs': 20000,
      }))['results']).single;

  test('waits for content that appears late instead of failing', () async {
    page.lateBy = 5;
    final r = await run('extract heading h1');
    expect(r['error'], isNull, reason: '$r');
    expect(asMap(r['data'])['heading'], 'Hello');
  });

  test('starts over once when the browser crashed before anything was clicked', () async {
    page.openErrors.add('the page crashed the browser; it restarts on the next try');
    final r = await run('extract heading h1');
    expect(r['error'], isNull, reason: '$r');
    expect(page.opens, 2);
  });

  test('does not start over after clicking: nothing is done twice', () async {
    page
      ..lateBy = -1
      ..clickCrashes = true;
    final r = await run('click #go');
    expect(r['error'], contains('not open'));
    expect(page.clicks, hasLength(1));
  });

  test('a failed step on a login page says the login ended', () async {
    page
      ..lateBy = 1000
      ..loginForm = true;
    final r = asMapList((await driver({
      'runs': [
        {'url': 'https://site.example/', 'steps': 'click #go'},
      ],
      'timeoutMs': 20000,
    }))['results']).single;
    expect(r['error'], contains('logged out of site.example'));
  });

  test('errors that a retry cannot fix are reported at once', () async {
    page.openErrors.add('could not load https://site.example/: net::ERR_NAME_NOT_RESOLVED');
    final r = await run('extract heading h1');
    expect(r['error'], contains('ERR_NAME_NOT_RESOLVED'));
    expect(page.opens, 1);
  });

  test('each driver has its own sessions', () {
    final other = BrowserDriver(page, saveScreenshot: (p) async => {});
    expect(other.runSession, isNot(driver.runSession));
    expect(other.agentSession, isNot(driver.agentSession));
  });
}
