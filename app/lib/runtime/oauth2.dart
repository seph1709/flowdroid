import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import '../data/credentials.dart';

/// OAuth2 authorization-code sign-in with PKCE, and token refresh, for `oauth2` credentials.
class OAuth2 {
  OAuth2({http.Client? client}) : _client = client ?? http.Client();

  static const callbackScheme = 'dev.flowdroid.flowdroid';
  static const redirectUri = '$callbackScheme:/oauth2redirect';

  final http.Client _client;

  /// Opens the service's sign-in page; returns the credential with fresh tokens. Call from the UI only.
  Future<Credential> connect(Credential credential) async {
    final v = credential.values;
    final verifier = _random(64);
    final state = _random(24);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final auth = Uri.parse(v['authUrl'] ?? '');
    final url = auth.replace(
      queryParameters: {
        ...auth.queryParameters,
        'response_type': 'code',
        'client_id': v['clientId'] ?? '',
        'redirect_uri': redirectUri,
        if ((v['scope'] ?? '').isNotEmpty) 'scope': v['scope']!,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final result = Uri.parse(
      await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: callbackScheme),
    );
    final error = result.queryParameters['error'];
    if (error != null) throw OAuth2Exception(result.queryParameters['error_description'] ?? error);
    if (result.queryParameters['state'] != state) throw const OAuth2Exception('the sign-in answer did not match');
    final code = result.queryParameters['code'];
    if (code == null) throw const OAuth2Exception('the service sent no code');
    return _withTokens(credential, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
      'code_verifier': verifier,
    });
  }

  /// A credential whose access token is valid for at least a minute more (refreshing it when it can).
  Future<Credential> fresh(Credential credential) async {
    final v = credential.values;
    final expires = int.tryParse(v['expiresAt'] ?? '');
    final soon = DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch;
    if (expires == null || expires > soon) return credential;
    if ((v['refreshToken'] ?? '').isEmpty) {
      throw OAuth2Exception('the sign-in for “${credential.name}” expired; open it in Credentials and tap Connect');
    }
    return _withTokens(credential, {'grant_type': 'refresh_token', 'refresh_token': v['refreshToken']!});
  }

  Future<Credential> _withTokens(Credential credential, Map<String, String> form) async {
    final v = credential.values;
    final response = await _client
        .post(
          Uri.parse(v['tokenUrl'] ?? ''),
          headers: {'Accept': 'application/json'},
          body: {
            ...form,
            'client_id': v['clientId'] ?? '',
            if ((v['clientSecret'] ?? '').isNotEmpty) 'client_secret': v['clientSecret']!,
          },
        )
        .timeout(const Duration(seconds: 30));
    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      body = decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      throw OAuth2Exception('the token service answered HTTP ${response.statusCode}');
    }
    final token = body['access_token'];
    if (token is! String) throw OAuth2Exception('${body['error_description'] ?? body['error'] ?? 'no access token'}');
    final expiresIn = body['expires_in'];
    return Credential(
      name: credential.name,
      type: credential.type,
      values: {
        ...v,
        'accessToken': token,
        if (body['refresh_token'] is String) 'refreshToken': body['refresh_token'] as String,
        'expiresAt': expiresIn is num
            ? '${DateTime.now().add(Duration(seconds: expiresIn.toInt())).millisecondsSinceEpoch}'
            : '',
      },
    );
  }

  static String _random(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class OAuth2Exception implements Exception {
  const OAuth2Exception(this.message);

  final String message;

  @override
  String toString() => message;
}
