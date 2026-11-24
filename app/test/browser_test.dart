import 'dart:convert';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/browser/browser_driver.dart';
import 'package:flowdroid/runtime/credential_resolver.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page that answers the driver's helper calls from memory.
class _FakePage implements BrowserPage {
  String url = '';
  final calls = <String>[];
  final screenshots = <String>[];
  bool showFails = false;
  int mutations = 0;

  /// The `fd.*` call inside the driver's script, e.g. `fd.click("#go")`.
  static String _call(String js) =>
      RegExp(r'const fd = window\.__fd; try \{ return (.*?); \} catch', dotAll: true).firstMatch(js)![1]!;

  @override
  Future<JsonMap> open(String session, String url, {required bool fast, required int timeoutMs}) async {
    calls.add('open $url fast=$fast');
    this.url = url;
    return {'url': url, 'title': 'Shop'};
  }

  @override
  Future<String?> eval(String session, String js) async {
    final call = _call(js);
    if (call.startsWith('fd.state()')) {
      return jsonEncode({'ready': 'complete', 'url': url, 'title': 'Shop', 'mutations': mutations});
    }
    calls.add(call);
    if (call.contains('#missing')) return jsonEncode({'error': 'nothing on the page matches #missing'});
    if (call.startsWith('fd.click("text=\\"Next\\"")')) url = 'https://shop.example/page2';
    if (call.startsWith('fd.click("3")')) url = 'https://evil.example/';
    if (call.startsWith('fd.present') || call.startsWith('fd.actionable')) return jsonEncode({'value': true});
    if (call.startsWith('fd.extract(".price", true')) {
      return jsonEncode({
        'value': ['9', '12'],
      });
    }
    if (call.startsWith('fd.extract')) return jsonEncode({'value': 'Cheap shoes'});
    if (call.startsWith('fd.snapshot')) {
      return jsonEncode({
        'url': url,
        'title': 'Shop',
        'elements': ['[1] link "Next"', '[2] input text "Search" value=""'],
        'text': 'Welcome',
        'more': false,
      });
    }
    if (call.startsWith('{ok: true, value:')) return jsonEncode({'ok': true, 'value': 42});
    // WebViews may hand back the JSON text of the JSON text.
    return jsonEncode(jsonEncode({'ok': true}));
  }

  @override
  Future<bool> back(String session) async {
    calls.add('back');
    url = 'https://shop.example/';
    return true;
  }

  @override
  Future<JsonMap> screenshot(String session, String path) async {
    screenshots.add(path);
    return {};
  }

  @override
  Future<JsonMap> show(String session) async {
    calls.add('show');
    return showFails ? {'error': 'not on screen'} : {};
  }

  @override
  Future<void> hide(String session) async => calls.add('hide');

  @override
  Future<void> finished(String session) async => calls.add('finished');
}

void main() {
  late _FakePage page;
  late BrowserDriver driver;

  setUp(() {
    page = _FakePage();
    driver = BrowserDriver(
      page,
      saveScreenshot: (path) async => {'path': path, 'mimeType': 'image/png'},
      poll: const Duration(milliseconds: 1),
      quiet: const Duration(milliseconds: 5),
    );
  });

  group('script', () {
    test('parses every step, skipping blanks and comments', () {
      final commands = BrowserDriver.parse('''
# find shoes
open https://shop.example
type input[name=q] red shoes
type "#full name" Ann Lee
click text="Next"
press
wait 1.5
wait for .results li
extract all titles .result h3
extract link a.first @href
scroll
back
screenshot after search
js document.title
''');
      expect(commands.map((c) => c.toString()), [
        '2:open target=https://shop.example text= name= all=false attr=',
        '3:type target=input[name=q] text=red shoes name= all=false attr=',
        '4:type target=#full name text=Ann Lee name= all=false attr=',
        '5:click target=text="Next" text= name= all=false attr=',
        '6:press target=Enter text= name= all=false attr=',
        '7:wait target= text=1.5 name= all=false attr=',
        '8:wait target=.results li text= name= all=false attr=',
        '9:extract target=.result h3 text= name=titles all=true attr=',
        '10:extract target=a.first text= name=link all=false attr=href',
        '11:scroll target= text= name= all=false attr=',
        '12:back target= text= name= all=false attr=',
        '13:screenshot target= text= name=after search all=false attr=',
        '14:js target= text=return (document.title) name= all=false attr=',
      ]);
    });

    test('points at the line that is wrong', () {
      Matcher fails(Object message) => throwsA(isA<BrowserException>().having((e) => e.message, 'message', message));
      expect(() => BrowserDriver.parse('click #a\nhover #b'), fails(startsWith('line 2: unknown step “hover”')));
      expect(
        () => BrowserDriver.parse('open example.com'),
        fails('line 1: open needs a URL starting with http:// or https://'),
      );
      expect(() => BrowserDriver.parse('wait soon'), fails(startsWith('line 1: wait needs seconds')));
      expect(
        () => BrowserDriver.parse('extract price'),
        fails(startsWith('line 1: extract needs a name and a selector')),
      );
      expect(() => BrowserDriver.parse('click'), fails(startsWith('line 1: click what?')));
    });
  });

  group('Browser step', () {
    test('runs the steps and returns the page, the data and screenshots', () async {
      final r = await driver.call({
        'runs': [
          {
            'url': 'https://shop.example/',
            'steps': 'type #q shoes\nclick text="Next"\nextract all prices .price\nextract name h1\njs return 6 * 7\nscreenshot',
          },
        ],
        'visible': true,
        'fast': true,
        'timeoutMs': 5000,
      });
      final result = asMapList(r['results']).single;
      expect(result['url'], 'https://shop.example/page2');
      expect(result['data'], {
        'prices': ['9', '12'],
        'name': 'Cheap shoes',
        'js': 42,
      });
      expect(asMapList(result['screenshots']).single['mimeType'], 'image/png');
      expect(page.calls.first, 'open https://shop.example/ fast=true');
      expect(
        page.calls,
        containsAllInOrder(['show', 'fd.type("#q", "shoes")', 'fd.click("text=\\"Next\\"")', 'finished']),
      );
      // A finished run leaves the page on screen for the person to close.
      expect(page.calls, isNot(contains('hide')));
    });

    test('a step that fails names its line, and the run goes on to the next item', () async {
      final r = await driver.call({
        'runs': [
          {'url': 'https://shop.example/', 'steps': 'click #ok\nclick #missing'},
          {'url': 'https://shop.example/', 'steps': 'extract name h1'},
        ],
        'timeoutMs': 5000,
      });
      final results = asMapList(r['results']);
      expect(results.first, {'error': 'line 2: nothing on the page matches #missing'});
      expect(asMap(results.last['data'])['name'], 'Cheap shoes');
    });

    test('stops at the timeout', () async {
      final r = await driver.call({
        'runs': [
          {'url': 'https://shop.example/', 'steps': 'wait 5'},
        ],
        'timeoutMs': 50,
      });
      expect(asMapList(r['results']).single['error'], 'the steps did not finish within 0 s');
    });
  });

  group('AI Agent browser tool', () {
    test('returns the page with numbered elements after each action', () async {
      final view = await driver.agent({'action': 'open', 'url': 'https://shop.example/'}, 'shop.example');
      expect(view, contains('URL: https://shop.example/'));
      expect(view, contains('[1] link "Next"'));
      final after = await driver.agent({'action': 'click', 'target': 'text="Next"'}, 'shop.example');
      expect(after, contains('URL: https://shop.example/page2'));
    });

    test('stays on the sites it may visit', () async {
      await expectLater(
        driver.agent({'action': 'open', 'url': 'https://evil.example/'}, 'shop.example'),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('may only visit'))),
      );
      await driver.agent({'action': 'open', 'url': 'https://www.shop.example/'}, 'shop.example');
      await expectLater(
        driver.agent({'action': 'click', 'target': '3'}, 'shop.example'),
        throwsA(isA<BrowserException>().having((e) => e.message, 'message', contains('went back'))),
      );
      expect(page.calls.last, 'back');
    });
  });

  group('Web session credential', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('sends the browser’s cookies only to its site', () async {
      final store = CredentialStore();
      await store.save(const Credential(name: 'Shop', type: 'webSession', values: {'site': 'https://shop.example'}));
      final asked = <String>[];
      final resolver = CredentialResolver(
        store,
        cookies: (url) async {
          asked.add(url);
          return 'sid=abc123';
        },
      );
      final (request, _) = await resolver.resolve({
        'url': 'https://api.shop.example/orders',
        'headers': <String, Object?>{},
        'credential': 'Shop',
        'auth': true,
      });
      expect(asMap(request['headers'])['Cookie'], 'sid=abc123');
      expect(asked, ['https://api.shop.example/orders']);
      await expectLater(
        resolver.resolve({
          'url': 'https://other.example/',
          'headers': <String, Object?>{},
          'credential': 'Shop',
          'auth': true,
        }),
        throwsA(isA<CredentialException>().having((e) => e.message, 'message', contains('is for shop.example'))),
      );
      final loggedOut = CredentialResolver(store, cookies: (_) async => '');
      await expectLater(
        loggedOut.resolve({
          'url': 'https://shop.example/',
          'headers': <String, Object?>{},
          'credential': 'Shop',
          'auth': true,
        }),
        throwsA(isA<CredentialException>().having((e) => e.message, 'message', contains('not logged in'))),
      );
    });
  });
}
