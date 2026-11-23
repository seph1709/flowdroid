import 'dart:convert';
import 'dart:io';

import '../core/json.dart';
import '../core/workflow.dart';
import 'credential_resolver.dart';
import 'file_store.dart';
import 'linux/linux_runtime.dart';
import 'mcp_client.dart';

/// Claude Code for the AI Chat and AI Agent nodes: runs each prompt with
/// `claude -p` in FlowDroid's Ubuntu, signed in with the person's own Claude account.
///
/// Answers the core's `cliChat` effect with
/// `{replies: [{text, model, sessionId, steps, stopReason, costUsd} | {error}]}`,
/// or `{error}` when Claude Code can't run at all.
///
/// A chat with `mode: 'agent'` is a task: Claude Code works in `folder` with
/// the `tools` it may use without asking, the node's `mcpServers`, and up to
/// `maxTurns` turns. A non-empty `session` key continues the Claude Code
/// conversation that key started, across runs; the keys are kept in [sessions].
///
/// An MCP server with `"credential": "<name>"` is filled in from that saved
/// credential when the task runs, so no key is written in the workflow: an
/// "MCP server" credential supplies the whole server (URL and sign-in header,
/// or command and environment); any other credential adds its sign-in header
/// to a web server and fills `{cred:field}` in the server's settings.
class CliChat {
  CliChat({required this.linux, required this.files, this.sessions, this.credentials});

  final LinuxRuntime linux;
  final FileStore files;

  /// `{key: sessionId}` for agent conversations that continue across runs.
  final File? sessions;

  /// Fills in the credentials MCP servers name.
  final CredentialResolver? credentials;

  static const _signIn = {'headerAuth', 'bearerAuth', 'basicAuth', 'oauth2'};

  static const _path = r'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"';

  /// Most conversation keys kept; the oldest are forgotten first.
  static const maxSessions = 500;

  Future<JsonMap> call(JsonMap effect) async {
    if (!await linux.ubuntuInstalled) {
      return {'error': 'Claude Code runs in FlowDroid’s Ubuntu: install it in Settings → Terminal'};
    }
    final replies = <JsonMap>[];
    for (final chat in asMapList(effect['chats'])) {
      final reply = await _one(chat);
      if (reply['fatal'] case final String fatal) return {'error': fatal};
      replies.add(reply);
    }
    return {'replies': replies};
  }

  Future<JsonMap> _one(JsonMap chat) async {
    final id = newId('chat_');
    final dir = Directory('${linux.rootfs.path}/tmp/$id');
    final inside = '/tmp/$id';
    await dir.create(recursive: true);
    try {
      var prompt = asString(chat['prompt']);
      final image = asString(chat['image']);
      if (image.isNotEmpty) {
        final File source;
        try {
          source = await files.existing(image);
        } on FileStoreException catch (e) {
          return {'error': e.message};
        }
        final name = 'image${_extension(source.path)}';
        await source.copy('${dir.path}/$name');
        prompt = 'Look at the image at $inside/$name (use the Read tool).\n\n$prompt';
      }
      await File('${dir.path}/prompt.txt').writeAsString(prompt);
      final system = asString(chat['system']);
      if (system.isNotEmpty) await File('${dir.path}/system.txt').writeAsString(system);
      final JsonMap servers;
      final List<String> secrets;
      try {
        (servers, secrets) = await expandServers(asMap(chat['mcpServers']));
      } on CredentialException catch (e) {
        return {'error': e.message};
      }
      if (servers.isNotEmpty) await File('${dir.path}/mcp.json').writeAsString(jsonEncode({'mcpServers': servers}));

      final key = asString(chat['session']);
      final known = key.isEmpty ? null : (await _sessions())[key];
      var reply = await _claude(chat, inside, resume: known);
      // The conversation may be gone (Claude Code's history was cleared); start a new one.
      if (known != null && reply['error'] is String && (reply['error']! as String).contains('No conversation found')) {
        reply = await _claude(chat, inside);
      }
      final session = asString(reply['sessionId']);
      if (key.isNotEmpty && session.isNotEmpty) await _remember(key, session);
      return _scrub(reply, secrets);
    } finally {
      await dir.delete(recursive: true).catchError((Object _) => dir);
    }
  }

  Future<JsonMap> _claude(JsonMap chat, String inside, {String? resume}) async {
    final r = await linux.run(
      '$_path; ${command(chat, inside, resume: resume)} < /dev/null',
      target: LinuxTarget.ubuntu,
      timeout: Duration(milliseconds: asInt(chat['timeoutMs'], 120000)),
    );
    if (r.error != null) return {'error': r.error};
    if (r.exitCode == 127) {
      return {'fatal': 'Claude Code is not installed in Ubuntu: set it up in the assistant settings'};
    }
    return parseResult(r.stdout, r.stderr, r.exitCode);
  }

  /// The shell command that runs [chat]; its prompt, instructions and MCP
  /// servers are files in [inside] (a folder in Ubuntu).
  static String command(JsonMap chat, String inside, {String? resume}) {
    final agent = chat['mode'] == 'agent';
    final hasSystem = asString(chat['system']).isNotEmpty;
    final hasServers = asMap(chat['mcpServers']).isNotEmpty;
    final model = asString(chat['model']);
    final folder = asString(chat['folder']);
    final parts = [
      'claude -p "\$(cat $inside/prompt.txt)"',
      '--output-format json',
      if (agent) ...[
        // Only these run without asking; with no one to ask, anything else is refused.
        '--allowedTools ${_quote(asList(chat['tools']).whereType<String>().join(','))}',
        '--max-turns ${asInt(chat['maxTurns'], 10)}',
        if (hasServers) '--mcp-config $inside/mcp.json',
        '--strict-mcp-config',
        // Keeps Claude Code's own instructions for using its tools.
        if (hasSystem) '--append-system-prompt "\$(cat $inside/system.txt)"',
        if (resume != null) '--resume ${_quote(resume)}',
      ] else ...[
        // Only reading the image; no shell, edits or MCP servers from the node.
        '--allowedTools Read --strict-mcp-config',
        if (hasSystem) '--system-prompt "\$(cat $inside/system.txt)"',
      ],
      if (model.isNotEmpty) '--model ${_quote(model)}',
    ].join(' ');
    final at = agent && folder.isNotEmpty ? folder : inside;
    return 'mkdir -p ${_quote(at)} && cd ${_quote(at)} && $parts';
  }

  /// [servers] with each `credential` replaced by what it holds, plus the
  /// secret values used (to scrub from the reply).
  Future<(JsonMap, List<String>)> expandServers(JsonMap servers) async {
    final out = <String, Object?>{};
    final secrets = <String>[];
    for (final MapEntry(:key, :value) in servers.entries) {
      final config = asMap(value);
      final name = asString(config['credential']);
      if (name.isEmpty) {
        out[key] = config;
        continue;
      }
      final resolver = credentials;
      if (resolver == null) throw const CredentialException('saved credentials are not available here');
      final saved = await resolver.open(name);
      secrets.addAll(saved.secrets);
      var expanded = Map.of(config)..remove('credential');
      final type = saved.credential.type;
      if (type == 'mcpServer') {
        expanded = _merge(_savedServer(saved), expanded);
        secrets.addAll(McpClient.parseEnv(saved.values['env'] ?? '').values.where((v) => v.length >= 6));
      } else if (_signIn.contains(type) && (expanded['url'] != null || expanded['type'] == 'http')) {
        expanded = _merge({'headers': saved.authHeader()}, expanded);
      }
      out[key] = _fill(expanded, saved.fill);
    }
    return (out, secrets);
  }

  /// An "MCP server" credential as Claude Code server settings.
  static JsonMap _savedServer(ResolvedCredential saved) {
    final v = saved.values;
    final url = (v['url'] ?? '').trim();
    final command = (v['command'] ?? '').trim();
    if (url.isNotEmpty) {
      final value = v['headerValue'] ?? '';
      final header = (v['headerName'] ?? '').trim();
      return {
        'type': 'http',
        'url': url,
        if (value.isNotEmpty) 'headers': {header.isEmpty ? 'Authorization' : header: value},
      };
    }
    if (command.isEmpty) throw CredentialException('“${saved.name}” has neither a URL nor a command');
    final env = McpClient.parseEnv(v['env'] ?? '');
    return {
      'command': 'bash',
      'args': ['-lc', command],
      if (env.isNotEmpty) 'env': env,
    };
  }

  /// [base] with [extra] on top; their `headers` and `env` are combined.
  static JsonMap _merge(JsonMap base, JsonMap extra) => {
    ...base,
    ...extra,
    for (final key in const ['headers', 'env'])
      if (base[key] != null || extra[key] != null) key: {...asMap(base[key]), ...asMap(extra[key])},
  };

  /// Every text in [value] with its `{cred:field}` placeholders filled.
  static Object? _fill(Object? value, String Function(String) fill) => switch (value) {
    final String s => fill(s),
    final List<Object?> list => [for (final v in list) _fill(v, fill)],
    final Map<Object?, Object?> map => {for (final e in map.entries) '${e.key}': _fill(e.value, fill)},
    _ => value,
  };

  static JsonMap _scrub(JsonMap reply, List<String> secrets) {
    if (secrets.isEmpty) return reply;
    String clean(String s) => secrets.fold(s, (t, secret) => t.replaceAll(secret, '•••'));
    return {for (final e in reply.entries) e.key: e.value is String ? clean(e.value! as String) : e.value};
  }

  /// The reply in `claude -p --output-format json` output.
  static JsonMap parseResult(String stdout, String stderr, int exitCode) {
    final line = stdout.trim().split('\n').where((l) => l.trim().startsWith('{')).lastOrNull;
    JsonMap? result;
    if (line != null) {
      try {
        result = asMap(jsonDecode(line));
      } on FormatException {
        result = null;
      }
    }
    if (result == null || result['type'] != 'result') {
      final last = stderr.trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      return {'error': last ?? 'Claude Code stopped (exit $exitCode)'};
    }
    final text = asString(result['result']).trim();
    final subtype = asString(result['subtype']);
    if (result['is_error'] == true || subtype.startsWith('error')) {
      if (subtype == 'error_max_turns') return {'error': 'stopped at the step limit without a final answer'};
      return {'error': text.isEmpty ? 'stopped with an error ($subtype)' : text};
    }
    final models = asMap(result['modelUsage']).keys;
    return {
      'text': text,
      if (models.isNotEmpty) 'model': models.first,
      if (result['session_id'] case final String id) 'sessionId': id,
      if (result['num_turns'] case final num turns) 'steps': turns,
      if (subtype.isNotEmpty) 'stopReason': subtype,
      if (result['total_cost_usd'] case final num cost) 'costUsd': cost,
    };
  }

  Future<Map<String, String>> _sessions() async {
    final file = sessions;
    if (file == null || !await file.exists()) return {};
    try {
      return asMap(jsonDecode(await file.readAsString())).map((k, v) => MapEntry(k, asString(v)));
    } on FormatException {
      return {};
    }
  }

  Future<void> _remember(String key, String session) async {
    final file = sessions;
    if (file == null) return;
    final all = await _sessions()
      ..remove(key)
      ..[key] = session;
    while (all.length > maxSessions) {
      all.remove(all.keys.first);
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(all));
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot > path.lastIndexOf('/') ? path.substring(dot).toLowerCase() : '';
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}
