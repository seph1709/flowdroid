import 'package:flowdroid/core/curl.dart';
import 'package:flowdroid/core/json_path.dart';
import 'package:flowdroid/runtime/linux/apt_progress.dart';
import 'package:flowdroid/ui/editor/data_mapping.dart';
import 'package:flowdroid/ui/editor/param_editors.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('curl import', () {
    test('a dev-tools copy with headers and a JSON body', () {
      final r = parseCurl(r'''
curl 'https://api.example.com/v1/users?limit=5' \
  -H 'accept: application/json' \
  -H "Authorization: Bearer abc123" \
  --data-raw '{"name":"Ada","tags":["x"]}' \
  --compressed
''');
      expect(r.method, 'POST');
      expect(r.url, 'https://api.example.com/v1/users?limit=5');
      expect(r.headers, [
        ('accept', 'application/json'),
        ('Authorization', 'Bearer abc123'),
        ('Content-Type', 'application/json'),
      ]);
      expect(r.body, '{\n  "name": "Ada",\n  "tags": [\n    "x"\n  ]\n}');
      expect(r.notes, isEmpty);
    });

    test('explicit method, inline flags, form data and -G', () {
      expect(parseCurl('curl -XPUT example.com/a -d x=1 -d y=2').toParams(), {
        'method': 'PUT',
        'url': 'https://example.com/a',
        'headers': [
          {'name': 'Content-Type', 'value': 'application/x-www-form-urlencoded'},
        ],
        'body': 'x=1&y=2',
      });
      final g = parseCurl('curl -G https://x.io/s --data-urlencode "q=a b" -m 9.5');
      expect(g.method, 'GET');
      expect(g.url, 'https://x.io/s?q=a+b');
      expect(g.timeoutSeconds, 10);
    });

    test('--json, -u and unsupported options', () {
      final r = parseCurl(r'''curl --json '{"a":1}' -u ann:pw -F file=@x.png https://h.io''');
      expect(r.method, 'POST');
      expect(r.headers.map((h) => h.$1), ['Authorization', 'Content-Type', 'Accept']);
      expect(r.headers.first.$2, 'Basic YW5uOnB3');
      expect(r.notes, hasLength(2));
    });

    test(r"$'…' strings and escaped quotes", () {
      expect(shellWords(r"""curl $'a\nb' "say \"hi\"" it\'s"""), ['curl', 'a\nb', 'say "hi"', "it's"]);
    });

    test('rejects what is not curl', () {
      expect(() => parseCurl('wget x'), throwsA(isA<CurlFormatException>()));
      expect(() => parseCurl("curl -H 'x"), throwsA(isA<CurlFormatException>()));
      expect(() => parseCurl('curl -s'), throwsA(isA<CurlFormatException>()));
    });

    test('round trip through toCurl', () {
      final params = {
        'method': 'PATCH',
        'url': 'https://a.io/{{ \$json.id }}',
        'headers': [
          {'name': 'X-Key', 'value': "it's"},
        ],
        'body': '{"a": 1}',
      };
      final back = parseCurl(toCurl(params));
      expect(back.method, 'PATCH');
      expect(back.url, r'https://a.io/{{ $json.id }}');
      expect(back.headers.first, ('X-Key', "it's"));
      expect(back.body, '{\n  "a": 1\n}');
    });
  });

  group('json paths', () {
    test('expressions for keys, indexes and odd names', () {
      expect(pathExpression(r'$json', ['user', 'name']), r'$json.user.name');
      expect(pathExpression(r'$json', ['tags', 0]), r'$json.tags[0]');
      expect(pathExpression(r'$json', ['first name', 'a"b']), r'$json["first name"]["a\"b"]');
      expect(pathExpression(r'$node["Fetch"].json', ['id']), r'$node["Fetch"].json.id');
    });

    test('values, containers and search', () {
      final v = {
        'a': {
          'b': [1, 2],
        },
        'name': 'Ada',
      };
      expect(valueAt(v, ['a', 'b', 1]), 2);
      expect(valueAt(v, ['x']), isNull);
      expect(containerPaths(v), {'', '.a', '.a.b'});
      expect(containerPaths(v, depth: 1), {'', '.a'});
      expect(matchingPaths(v, 'ada'), {'', '.name'});
      expect(matchingPaths(v, 'b'), {'', '.a', '.a.b'});
    });
  });

  group('mapping', () {
    test('inserts wrapped, or bare inside an open expression', () {
      var v = const TextEditingValue(text: 'Hi ', selection: TextSelection.collapsed(offset: 3));
      v = insertExpression(v, r'$json.name');
      expect(v.text, r'Hi {{ $json.name }}');
      expect(v.selection.baseOffset, v.text.length);
      v = insertExpression(
        const TextEditingValue(text: '{{  }}', selection: TextSelection.collapsed(offset: 3)),
        r'$json.a',
      );
      expect(v.text, r'{{ $json.a }}');
    });
  });

  group('autocomplete', () {
    final sources = [
      const DataSource(
        title: 'Input',
        root: r'$json',
        items: true,
        value: [
          {
            'user': {'name': 'Ada', 'first name': 'A'},
            'id': 1,
          },
        ],
      ),
      const DataSource(
        title: 'Fetch',
        root: r'$node["Fetch"].json',
        items: true,
        value: [
          {'status': 'ok', 'size': 2},
        ],
      ),
    ];
    ({String partial, List<String> keys})? at(String text) => completions(text, text.length, sources);

    test('suggests keys after a dot inside an expression', () {
      expect(at(r'{{ $json.')?.keys, ['user', 'id']);
      expect(at(r'{{ $json.u')?.keys, ['user']);
      expect(at(r'{{ $json.user.')?.keys, ['name', 'first name']);
      expect(at(r'{{ $node["Fetch"].json.s')?.keys, ['status', 'size']);
    });

    test('stays quiet outside expressions and on unknown paths', () {
      expect(at(r'$json.'), isNull);
      expect(at(r'{{ $json.id }} $json.'), isNull);
      expect(at(r'{{ $json.nope.'), isNull);
      expect(at(r'{{ $json.user.name'), isNull);
    });
  });

  group('json formatting', () {
    test('keeps expressions in and out of strings', () {
      expect(
        formatJsonTemplate(r'{"id": {{ $json.id }}, "msg": "Hi {{ $json.name }}"}'),
        '{\n  "id": {{ \$json.id }},\n  "msg": "Hi {{ \$json.name }}"\n}',
      );
      expect(formatJsonTemplate('{"a": '), isNull);
    });
  });

  group('apt progress', () {
    test('reads download and install status lines', () {
      final p = AptProgress();
      expect(p.feed('dlstatus:1:12.5:Retrieving file 1 of 8'), (step: 'Downloading packages', fraction: 0.0625));
      expect(p.feed('pmstatus:nodejs:60:Unpacking nodejs'), (step: 'Installing', fraction: 0.8));
      expect(p.feed('random output'), isNull);
    });
  });
}
