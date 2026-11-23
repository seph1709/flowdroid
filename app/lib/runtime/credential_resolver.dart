import 'dart:convert';

import '../core/json.dart';
import '../data/credentials.dart';
import 'google_auth.dart';
import 'oauth2.dart';

/// Fills `{cred:field}` / `{cred:field|default}` placeholders in a request
/// from the credential it names, right before it is sent.
class CredentialResolver {
  CredentialResolver(this.store, {GoogleAuth? google, OAuth2? oauth2, this.cookies})
    : _google = google ?? GoogleAuth(),
      _oauth2 = oauth2 ?? OAuth2();

  final CredentialStore store;

  /// The in-app browser's cookies for a URL, for "Web session" credentials; null where there is no browser.
  final Future<String> Function(String url)? cookies;
  final GoogleAuth _google;
  final OAuth2 _oauth2;

  /// The credential named [name], ready to use: OAuth2 tokens refreshed, a
  /// Google access token fetched.
  Future<ResolvedCredential> open(String name) async {
    var credential = await store.byName(name);
    if (credential == null) throw CredentialException('credential "$name" not found; add it in Settings → Credentials');
    if (credential.type == 'oauth2') {
      final refreshed = await _oauth2.fresh(credential);
      if (!identical(refreshed, credential)) await store.save(refreshed);
      credential = refreshed;
    }
    final values = Map.of(credential.values);
    if (credential.type == 'google') {
      values['accessToken'] = await _google.accessToken(values['webClientId'] ?? '');
    }
    return ResolvedCredential(credential, values);
  }

  /// The request with secrets filled in, plus the secret values (to scrub from error messages).
  Future<(JsonMap, List<String>)> resolve(JsonMap request) async {
    final name = request['credential'];
    if (name is! String || name.isEmpty) return (request, const <String>[]);
    final opened = await open(name);
    final credential = opened.credential;
    final fill = opened.fill;
    final resolved = {
      ...request,
      'url': fill(asString(request['url'])),
      'headers': asMap(request['headers']).map((k, v) => MapEntry(k, fill(asString(v)))),
      if (request['body'] is String) 'body': fill(request['body']! as String),
    }..remove('credential');
    if (request['auth'] == true) {
      final header = credential.type == 'webSession'
          ? await _webSession(credential, asString(resolved['url']))
          : _authHeader(credential);
      resolved
        ..remove('auth')
        ..['headers'] = {...asMap(resolved['headers']), ...header};
    }
    return (resolved, opened.secrets);
  }
}

/// The browser login's cookies, only for requests to that site (or its subdomains).
extension on CredentialResolver {
  Future<Map<String, String>> _webSession(Credential c, String url) async {
    final read = cookies;
    if (read == null) throw const CredentialException('web sessions need the phone’s browser');
    final site = Uri.tryParse(c.values['site'] ?? '')?.host.toLowerCase() ?? '';
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (site.isEmpty) throw CredentialException('credential "${c.name}" has no site');
    if (host != site && !host.endsWith('.$site') && !site.endsWith('.$host')) {
      throw CredentialException('credential "${c.name}" is for $site, not $host');
    }
    final value = await read(url);
    if (value.isEmpty) {
      throw CredentialException('not logged in to $site: open Settings → Credentials → ${c.name} and tap Log in');
    }
    return {'Cookie': value};
  }
}

/// A credential's values, ready to fill `{cred:field}` placeholders or sign a request.
class ResolvedCredential {
  ResolvedCredential(this.credential, this.values);

  final Credential credential;
  final Map<String, String> values;

  static final _placeholder = RegExp(r'\{cred:([A-Za-z]+)(?:\|([^}]*))?\}');

  String get name => credential.name;

  /// Values long enough to be secrets, to scrub from error messages.
  List<String> get secrets => values.values.where((v) => v.length >= 6).toList();

  /// [text] with `{cred:field}` / `{cred:field|default}` filled from this credential.
  String fill(String text) => text.replaceAllMapped(_placeholder, (m) {
    final value = values[m[1]!] ?? '';
    if (value.isNotEmpty) return value;
    final fallback = m[2];
    if (fallback != null) return fallback;
    throw CredentialException('credential "$name" has no ${m[1]}');
  });

  /// The header a web API call signs in with (API key, bearer, basic or OAuth2).
  Map<String, String> authHeader() => _authHeader(Credential(name: name, type: credential.type, values: values));
}

/// The header HTTP Request sends for an authentication credential.
Map<String, String> _authHeader(Credential c) {
  final v = c.values;
  return switch (c.type) {
    'headerAuth' => {v['name'] ?? 'X-API-Key': v['value'] ?? ''},
    'bearerAuth' => {'Authorization': 'Bearer ${v['token'] ?? ''}'},
    'basicAuth' => {
      'Authorization': 'Basic ${base64.encode(utf8.encode('${v['user'] ?? ''}:${v['password'] ?? ''}'))}',
    },
    'oauth2' => {'Authorization': 'Bearer ${v['accessToken'] ?? ''}'},
    _ => throw CredentialException('credential "${c.name}" cannot be used to sign in to a web API'),
  };
}

class CredentialException implements Exception {
  const CredentialException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Replaces each secret in [text] with dots, so errors never show a key or token.
String scrub(String text, List<String> secrets) {
  var out = text;
  for (final s in secrets) {
    out = out.replaceAll(s, '•••');
  }
  return out;
}
