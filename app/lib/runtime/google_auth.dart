import 'package:google_sign_in/google_sign_in.dart';

/// Google sign-in for the Sheets, Gmail and Calendar nodes.
///
/// Signing in (with its consent screen) happens in the app; workflows then
/// reuse that grant silently, also in the background.
class GoogleAuth {
  static const scopes = [
    'https://www.googleapis.com/auth/spreadsheets',
    'https://www.googleapis.com/auth/gmail.send',
    'https://www.googleapis.com/auth/calendar.events',
  ];

  static String? _initializedFor;

  Future<void> _init(String webClientId) async {
    if (webClientId.isEmpty) throw const GoogleAuthException('the Google credential has no web client ID');
    if (_initializedFor == webClientId) return;
    await GoogleSignIn.instance.initialize(serverClientId: webClientId);
    _initializedFor = webClientId;
  }

  /// Interactive: picks an account and grants the scopes. Call from the UI only.
  Future<String> signIn(String webClientId) async {
    await _init(webClientId);
    final account = await GoogleSignIn.instance.authenticate(scopeHint: scopes);
    await account.authorizationClient.authorizeScopes(scopes);
    return account.email;
  }

  /// Silent: an access token from an earlier sign-in, or an error asking to sign in again.
  Future<String> accessToken(String webClientId) async {
    await _init(webClientId);
    final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
    final client = account?.authorizationClient ?? GoogleSignIn.instance.authorizationClient;
    final authz = await client.authorizationForScopes(scopes);
    if (authz == null) {
      throw const GoogleAuthException(
        'Google access expired; open the Google credential in FlowDroid and sign in again',
      );
    }
    return authz.accessToken;
  }
}

class GoogleAuthException implements Exception {
  const GoogleAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
