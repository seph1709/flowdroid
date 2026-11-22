import 'dart:convert';

import '../core/json.dart';
import '../data/credentials.dart';
import 'google_auth.dart';
import 'oauth2.dart';

/// Fills `{cred:field}` / `{cred:field|default}` placeholders in a request
/// from the credential it names, right before it is sent.
class CredentialResolver {
  CredentialResolver(this.store, {GoogleAuth? google, OAuth2? oauth2})
    : _google = google ?? GoogleAuth(),
      _oauth2 = oauth2 ?? OAuth2();

  final CredentialStore store;
  final GoogleAuth _google;
  final OAuth2 _oauth2;

  static final _placeholder = RegExp(r'\{cred:([A-Za-z]+)(?:\|([^}]*))?\}');

  /// The request with secrets filled in, plus the secret values (to scrub from error messages).
  Future<(JsonMap, List<String>)> resolve(JsonMap request) async {
    final name = request['credential'];
    if (name is! String || name.isEmpty) return (request, const <String>[]);
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
    String fill(String text) => text.replaceAllMapped(_placeholder, (m) {
      final value = values[m[1]!] ?? '';
      if (value.isNotEmpty) return value;
      final fallback = m[2];
      if (fallback != null) return fallback;
      throw CredentialException('credential "$name" has no ${m[1]}');
    });
    final resolved = {
      ...request,
      'url': fill(asString(request['url'])),
      'headers': asMap(request['headers']).map((k, v) => MapEntry(k, fill(asString(v)))),
      if (request['body'] is String) 'body': fill(request['body']! as String),
    }..remove('credential');
    if (request['auth'] == true) {
      resolved
        ..remove('auth')
        ..['headers'] = {...asMap(resolved['headers']), ..._authHeader(credential)};
    }
    final secrets = values.values.where((v) => v.length >= 6).toList();
    return (resolved, secrets);
  }
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
