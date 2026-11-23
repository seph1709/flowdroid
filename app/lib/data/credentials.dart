import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/json.dart';

/// One field a credential type asks for.
class CredentialField {
  const CredentialField(
    this.key,
    this.label, {
    this.secret = false,
    this.optional = false,
    this.hidden = false,
    this.hint,
  });

  final String key;
  final String label;
  final bool secret;
  final bool optional;

  /// Filled in by FlowDroid (e.g. OAuth2 tokens), not typed by the user.
  final bool hidden;
  final String? hint;
}

/// A kind of credential: what it is for and which fields it holds.
class CredentialType {
  const CredentialType(this.id, this.label, this.fields, {required this.help});

  final String id;
  final String label;
  final List<CredentialField> fields;
  final String help;
}

const _apiKey = CredentialField('apiKey', 'API key', secret: true);

/// Every credential type a node can ask for (matches the `credential` param options in the core).
const credentialTypes = <CredentialType>[
  CredentialType('anthropic', 'Anthropic (Claude)', [
    _apiKey,
  ], help: 'Create a key at console.anthropic.com → API keys.'),
  CredentialType('openai', 'OpenAI', [
    _apiKey,
    CredentialField('baseUrl', 'Base URL', optional: true, hint: 'https://api.openai.com/v1'),
  ], help: 'Create a key at platform.openai.com → API keys.'),
  CredentialType('elevenlabs', 'ElevenLabs (voices)', [
    _apiKey,
  ], help: 'Create a key at elevenlabs.io → Developers → API keys.'),
  CredentialType('gemini', 'Google Gemini', [_apiKey], help: 'Create a key at aistudio.google.com → Get API key.'),
  CredentialType('openaiCompatible', 'OpenAI-compatible (Ollama, OpenRouter, …)', [
    CredentialField('baseUrl', 'Base URL', hint: 'http://192.168.1.10:11434/v1'),
    CredentialField('apiKey', 'API key', secret: true, optional: true),
  ], help: 'Any server that speaks the OpenAI chat completions API.'),
  CredentialType('telegram', 'Telegram bot', [
    CredentialField('botToken', 'Bot token', secret: true, hint: '123456:ABC-…'),
  ], help: 'Talk to @BotFather in Telegram, send /newbot, and paste the token it gives you.'),
  CredentialType('discordWebhook', 'Discord webhook', [
    CredentialField('url', 'Webhook URL', secret: true, hint: 'https://discord.com/api/webhooks/…'),
  ], help: 'In Discord: channel settings → Integrations → Webhooks → New webhook → Copy URL.'),
  CredentialType('discordBot', 'Discord bot', [
    CredentialField('botToken', 'Bot token', secret: true),
  ], help: 'discord.com/developers → your app → Bot → Reset token. Invite the bot to your server.'),
  CredentialType('supabase', 'Supabase', [
    CredentialField('url', 'Project URL', hint: 'https://xyz.supabase.co'),
    CredentialField('serviceKey', 'API key', secret: true, hint: 'anon or service_role'),
  ], help: 'Supabase dashboard → Project settings → API.'),
  CredentialType('airtable', 'Airtable', [
    CredentialField('token', 'Personal access token', secret: true),
  ], help: 'airtable.com/create/tokens → create a token with data.records:read/write on your base.'),
  CredentialType('notion', 'Notion', [
    CredentialField('token', 'Integration secret', secret: true),
  ], help: 'notion.so/my-integrations → new integration; then share your database with it.'),
  CredentialType(
    'google',
    'Google account',
    [CredentialField('webClientId', 'OAuth web client ID', hint: '…apps.googleusercontent.com')],
    help:
        'Needs a Google Cloud project with the Sheets, Gmail, Calendar and Drive APIs enabled, an Android OAuth '
        'client for dev.flowdroid.flowdroid, and a Web client whose ID goes here. Then tap Sign in with Google.',
  ),
  CredentialType('email', 'Email account (IMAP/SMTP)', [
    CredentialField('email', 'Email address', hint: 'you@example.com'),
    CredentialField('password', 'Password', secret: true, hint: 'an app password for Gmail, Outlook, iCloud'),
    CredentialField('name', 'Your name', optional: true),
    CredentialField('imapHost', 'IMAP server', hint: 'imap.gmail.com'),
    CredentialField('imapPort', 'IMAP port', optional: true, hint: '993'),
    CredentialField('smtpHost', 'SMTP server', hint: 'smtp.gmail.com'),
    CredentialField('smtpPort', 'SMTP port', optional: true, hint: '465 (or 587)'),
  ], help: 'Your provider lists its IMAP and SMTP servers. With two-step sign-in, create an app password.'),
  CredentialType('webhookAuth', 'Webhook key', [
    CredentialField('headerName', 'Header name', optional: true, hint: 'X-FlowDroid-Key'),
    CredentialField('value', 'Key', secret: true),
  ], help: 'Callers must send this header with this exact value, or the webhook answers 401.'),
  CredentialType('headerAuth', 'API key in a header', [
    CredentialField('name', 'Header name', hint: 'X-API-Key'),
    CredentialField('value', 'Value', secret: true),
  ], help: 'For HTTP Request: adds this header to every call.'),
  CredentialType('bearerAuth', 'Bearer token', [
    CredentialField('token', 'Token', secret: true),
  ], help: 'For HTTP Request: sends “Authorization: Bearer <token>”.'),
  CredentialType('basicAuth', 'Username and password', [
    CredentialField('user', 'Username'),
    CredentialField('password', 'Password', secret: true),
  ], help: 'For HTTP Request: sends HTTP Basic authentication.'),
  CredentialType(
    'webSession',
    'Web session (browser login)',
    [CredentialField('site', 'Site', hint: 'https://example.com')],
    help:
        'Log in to the site once in FlowDroid’s browser (button below). HTTP Request then sends that login’s cookies '
        'to the site; they stay in the browser and never appear in the workflow or run history.',
  ),
  CredentialType(
    'mcpServer',
    'MCP server',
    [
      CredentialField('url', 'Server URL', optional: true, hint: 'https://example.com/mcp'),
      CredentialField(
        'command',
        'Or a command (runs in Ubuntu)',
        optional: true,
        hint: 'npx -y @modelcontextprotocol/server-github',
      ),
      CredentialField('headerName', 'Sign-in header', optional: true, hint: 'Authorization'),
      CredentialField('headerValue', 'Header value', secret: true, optional: true, hint: 'Bearer …'),
      CredentialField('env', 'Environment for the command', secret: true, optional: true, hint: 'TOKEN=…; OTHER=…'),
    ],
    help:
        'A server to pick by name in MCP Client, AI Agent tools and Claude Code. Give a URL for a server on the web, '
        'or a command for one FlowDroid runs in Ubuntu. Keys stay in encrypted storage.',
  ),
  CredentialType(
    'oauth2',
    'OAuth2 (any service)',
    [
      CredentialField('authUrl', 'Authorization URL', hint: 'https://github.com/login/oauth/authorize'),
      CredentialField('tokenUrl', 'Token URL', hint: 'https://github.com/login/oauth/access_token'),
      CredentialField('clientId', 'Client ID'),
      CredentialField('clientSecret', 'Client secret', secret: true, optional: true),
      CredentialField('scope', 'Scopes', optional: true, hint: 'space separated'),
      CredentialField('accessToken', 'Access token', secret: true, hidden: true),
      CredentialField('refreshToken', 'Refresh token', secret: true, hidden: true),
      CredentialField('expiresAt', 'Expires', hidden: true),
    ],
    help:
        'Register an app with the service and set its redirect URL to dev.flowdroid.flowdroid:/oauth2redirect. '
        'Save, then tap Connect.',
  ),
];

CredentialType? credentialType(String id) {
  for (final t in credentialTypes) {
    if (t.id == id) return t;
  }
  return null;
}

/// A saved credential. [values] hold the secrets and never leave the phone's encrypted storage.
class Credential {
  const Credential({required this.name, required this.type, required this.values});

  Credential.fromJson(JsonMap json)
    : name = asString(json['name']),
      type = asString(json['type']),
      values = asMap(json['values']).map((k, v) => MapEntry(k, asString(v)));

  final String name;
  final String type;
  final Map<String, String> values;

  JsonMap toJson() => {'name': name, 'type': type, 'values': values};
}

/// Credentials in Android's encrypted storage (Keystore-backed), shared by every isolate.
class CredentialStore extends ChangeNotifier {
  CredentialStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'flowdroid.credentials.v1';
  final FlutterSecureStorage _storage;

  Future<List<Credential>> all() async {
    final text = await _storage.read(key: _key);
    if (text == null || text.isEmpty) return [];
    try {
      return asMapList(jsonDecode(text)).map(Credential.fromJson).toList()..sort((a, b) => a.name.compareTo(b.name));
    } on FormatException {
      return [];
    }
  }

  Future<Credential?> byName(String name) async {
    for (final c in await all()) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// Saves [credential], replacing the one named [replacing] (or the same name).
  Future<void> save(Credential credential, {String? replacing}) async {
    final list = await all()
      ..removeWhere((c) => c.name == credential.name || c.name == replacing)
      ..add(credential);
    await _write(list);
  }

  Future<void> delete(String name) async => _write((await all())..removeWhere((c) => c.name == name));

  Future<void> _write(List<Credential> list) async {
    await _storage.write(key: _key, value: jsonEncode(list.map((c) => c.toJson()).toList()));
    notifyListeners();
  }
}
