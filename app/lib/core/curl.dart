/// Turns a `curl` command (as copied from browser dev tools or API docs) into
/// HTTP Request parameters, and back.
library;

import 'dart:convert';

import 'json.dart';

class CurlRequest {
  const CurlRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    this.timeoutSeconds,
    this.notes = const [],
  });

  final String method;
  final String url;
  final List<(String, String)> headers;
  final String body;
  final int? timeoutSeconds;

  /// Options that were understood but can't be carried over, for telling the user.
  final List<String> notes;

  /// Parameters for the HTTP Request node.
  JsonMap toParams() => {
    'method': method,
    'url': url,
    'headers': [
      for (final (name, value) in headers) {'name': name, 'value': value},
    ],
    'body': body,
    'timeout': ?timeoutSeconds,
  };
}

class CurlFormatException implements Exception {
  const CurlFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Splits a shell command line into words: quotes, `$'…'`, escapes and `\` line breaks.
List<String> shellWords(String input) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var i = 0;
  final s = input.replaceAll('\r\n', '\n');
  while (i < s.length) {
    final ch = s[i];
    if (ch == r'\' && i + 1 < s.length && s[i + 1] == '\n') {
      i += 2; // line continuation
      continue;
    }
    if (ch == ' ' || ch == '\t' || ch == '\n') {
      if (inWord) {
        words.add('$word');
        word.clear();
        inWord = false;
      }
      i++;
      continue;
    }
    inWord = true;
    if (ch == "'") {
      final end = s.indexOf("'", i + 1);
      if (end < 0) throw const CurlFormatException('a quote (\') is not closed');
      word.write(s.substring(i + 1, end));
      i = end + 1;
    } else if (ch == r'$' && i + 1 < s.length && s[i + 1] == "'") {
      i += 2;
      while (i < s.length && s[i] != "'") {
        if (s[i] == r'\' && i + 1 < s.length) {
          final e = s[i + 1];
          word.write(switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            _ => e,
          });
          i += 2;
        } else {
          word.write(s[i++]);
        }
      }
      if (i >= s.length) throw const CurlFormatException("a quote (\$') is not closed");
      i++;
    } else if (ch == '"') {
      i++;
      while (i < s.length && s[i] != '"') {
        if (s[i] == r'\' && i + 1 < s.length && r'"\$`'.contains(s[i + 1])) {
          word.write(s[i + 1]);
          i += 2;
        } else if (s[i] == r'\' && i + 1 < s.length && s[i + 1] == '\n') {
          i += 2;
        } else {
          word.write(s[i++]);
        }
      }
      if (i >= s.length) throw const CurlFormatException('a quote (") is not closed');
      i++;
    } else if (ch == r'\' && i + 1 < s.length) {
      word.write(s[i + 1]);
      i += 2;
    } else {
      word.write(ch);
      i++;
    }
  }
  if (inWord) words.add('$word');
  return words;
}

const _ignored = {
  '-s', '--silent', '-S', '--show-error', '-L', '--location', '-k', '--insecure', '-v', '--verbose', //
  '-i', '--include', '--compressed', '-g', '--globoff', '-f', '--fail', '-#', '--progress-bar', '-N', '--no-buffer',
};
const _ignoredWithValue = {'-o', '--output', '--connect-timeout', '--retry', '-w', '--write-out', '-x', '--proxy'};

/// Parses a curl command. Throws [CurlFormatException] when it isn't one.
CurlRequest parseCurl(String command) {
  var words = shellWords(command.trim());
  if (words.isEmpty || words.first != 'curl') {
    throw const CurlFormatException('this does not start with "curl"');
  }
  words = words.sublist(1);
  String? method;
  String? url;
  final headers = <(String, String)>[];
  final data = <String>[];
  String? json;
  var get = false;
  int? timeout;
  final notes = <String>[];

  String value(int i, String flag) {
    if (i >= words.length) throw CurlFormatException('$flag needs a value');
    return words[i];
  }

  for (var i = 0; i < words.length; i++) {
    var w = words[i];
    // --flag=value
    String? inline;
    if (w.startsWith('--') && w.contains('=')) {
      inline = w.substring(w.indexOf('=') + 1);
      w = w.substring(0, w.indexOf('='));
    } else if (RegExp(r'^-[XHduAebm].+').hasMatch(w)) {
      // -XPOST, -H'Accept: x'
      inline = w.substring(2);
      w = w.substring(0, 2);
    }
    String next() => inline ?? value(++i, w);
    switch (w) {
      case '-X' || '--request':
        method = next().toUpperCase();
      case '-H' || '--header':
        final h = next();
        final colon = h.indexOf(':');
        if (colon > 0) headers.add((h.substring(0, colon).trim(), h.substring(colon + 1).trim()));
      case '-d' || '--data' || '--data-raw' || '--data-binary' || '--data-ascii':
        final d = next();
        if (d.startsWith('@') && w != '--data-raw') {
          notes.add('the body was read from a file (${d.substring(1)}); paste its contents into Body');
        } else {
          data.add(d);
        }
      case '--data-urlencode':
        final d = next();
        final eq = d.indexOf('=');
        data.add(
          eq < 0
              ? Uri.encodeQueryComponent(d)
              : '${d.substring(0, eq)}=${Uri.encodeQueryComponent(d.substring(eq + 1))}',
        );
      case '--json':
        json = next();
      case '-u' || '--user':
        headers.add(('Authorization', 'Basic ${base64.encode(utf8.encode(next()))}'));
        notes.add('the username and password are in an Authorization header; a Basic auth credential keeps them safer');
      case '-A' || '--user-agent':
        headers.add(('User-Agent', next()));
      case '-e' || '--referer':
        headers.add(('Referer', next()));
      case '-b' || '--cookie':
        headers.add(('Cookie', next()));
      case '-G' || '--get':
        get = true;
      case '-I' || '--head':
        method = 'HEAD';
      case '-m' || '--max-time':
        timeout = double.tryParse(next())?.ceil();
      case '--url':
        url = next();
      case '-F' || '--form':
        next();
        notes.add('multipart form fields (-F) are not supported and were left out');
      default:
        if (_ignored.contains(w)) continue;
        if (_ignoredWithValue.contains(w)) {
          if (inline == null) i++;
          continue;
        }
        if (w.startsWith('-')) {
          notes.add('$w was ignored');
        } else {
          url ??= w;
        }
    }
  }

  if (url == null || url.isEmpty) throw const CurlFormatException('no URL found');
  if (!url.contains('://')) url = 'https://$url';

  bool hasHeader(String name) => headers.any((h) => h.$1.toLowerCase() == name.toLowerCase());
  var body = '';
  if (json != null) {
    body = json;
    if (!hasHeader('Content-Type')) headers.add(('Content-Type', 'application/json'));
    if (!hasHeader('Accept')) headers.add(('Accept', 'application/json'));
  } else if (data.isNotEmpty) {
    final joined = data.join('&');
    if (get) {
      url = '$url${url.contains('?') ? '&' : '?'}$joined';
    } else {
      body = joined;
      if (!hasHeader('Content-Type')) {
        headers.add((
          'Content-Type',
          _looksLikeJson(joined) ? 'application/json' : 'application/x-www-form-urlencoded',
        ));
      }
    }
  }
  if (_looksLikeJson(body)) {
    try {
      body = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } on FormatException {
      // Keep it as typed.
    }
  }
  final m = method ?? (body.isNotEmpty ? 'POST' : 'GET');
  const supported = {'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'};
  if (!supported.contains(m)) notes.add('method $m is not supported; GET is used');
  return CurlRequest(
    method: supported.contains(m) ? m : 'GET',
    url: url,
    headers: headers,
    body: body,
    timeoutSeconds: timeout,
    notes: notes,
  );
}

bool _looksLikeJson(String s) {
  final t = s.trimLeft();
  return t.startsWith('{') || t.startsWith('[');
}

String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// A curl command for HTTP Request [params] (expressions are left as written).
String toCurl(JsonMap params) {
  final method = asString(params['method'], 'GET').toUpperCase();
  final parts = ['curl'];
  if (method != 'GET') parts.add('-X $method');
  parts.add(_quote(asString(params['url'])));
  for (final h in asMapList(params['headers'])) {
    final name = asString(h['name']);
    if (name.isNotEmpty) parts.add('-H ${_quote('$name: ${asString(h['value'])}')}');
  }
  final body = params['body'];
  final text = body is String ? body : (body == null ? '' : jsonEncode(body));
  if (text.trim().isNotEmpty) parts.add('--data-raw ${_quote(text)}');
  return parts.join(' \\\n  ');
}
