import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'credential_resolver.dart';
import 'linux/linux_runtime.dart';

/// The MCP Client node's host side: speaks the Model Context Protocol
/// (JSON-RPC 2.0) to a server on the web (Streamable HTTP) or to a command run
/// in FlowDroid's Ubuntu (stdio).
///
/// Answers the core's `mcp` effect `{server, calls: [{method, params}], timeoutMs}`
/// with `{results: [{result} | {error}]}`, or `{error}` when the server can't
/// be reached at all, and the AI Agent's `mcpList` effect with each server's
/// tools. A server is `{transport: 'http', url, credential?}`,
/// `{transport: 'stdio', command}` or `{transport: 'saved', credential}` (an
/// "MCP server" credential). Sessions stay open for [idle] after their last
/// use, so a workflow that calls the same server for many items initializes only once.
class McpClient {
  McpClient({
    required this.linux,
    required this.credentials,
    http.Client? client,
    this.idle = const Duration(minutes: 2),
  }) : _client = client ?? http.Client();

  /// The protocol version FlowDroid asks for; the server may answer with another it supports.
  static const protocolVersion = '2025-06-18';

  final LinuxRuntime linux;
  final CredentialResolver credentials;
  final Duration idle;
  final http.Client _client;
  final _sessions = <String, Future<McpSession>>{};

  Future<JsonMap> call(JsonMap effect) async {
    final server = asMap(effect['server']);
    final timeout = Duration(milliseconds: asInt(effect['timeoutMs'], 60000));
    final results = <JsonMap>[];
    for (final call in asMapList(effect['calls'])) {
      try {
        results.add({'result': await _request(server, asString(call['method']), asMap(call['params']), timeout)});
      } on McpException catch (e) {
        // A JSON-RPC error fails only this call; an unreachable server fails them all.
        if (e.kind == McpFailure.server) {
          results.add({'error': e.message});
          continue;
        }
        return {'error': e.message};
      }
    }
    return {'results': results};
  }

  /// The AI Agent's `mcpList` effect: `{servers: [{name, config}], timeoutMs}`
  /// → `{results: [{tools} | {error}]}`, one per server.
  Future<JsonMap> listTools(JsonMap effect) async {
    final timeout = Duration(milliseconds: asInt(effect['timeoutMs'], 60000));
    final results = <JsonMap>[];
    for (final entry in asMapList(effect['servers'])) {
      try {
        final server = await serverFor(asString(entry['config']));
        results.add({'tools': await listAll(server, 'tools/list', timeout)});
      } on McpException catch (e) {
        results.add({'error': e.message});
      }
    }
    return {'results': results};
  }

  /// Every item a list method returns (`tools/list`, `resources/list`,
  /// `prompts/list`), following the server's pages.
  Future<List<JsonMap>> listAll(JsonMap server, String method, Duration timeout) async {
    final key = switch (method) {
      'resources/list' => 'resources',
      'prompts/list' => 'prompts',
      _ => 'tools',
    };
    final all = <JsonMap>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final result = await _request(server, method, {'cursor': ?cursor}, timeout);
      all.addAll(asMapList(result[key]));
      cursor = result['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return all;
  }

  /// Calls [tool] on the server [config] names (see [serverFor]) and returns
  /// its text, for the AI Agent; a tool error throws.
  Future<String> callTool(String config, String tool, JsonMap arguments, Duration timeout) async {
    final server = await serverFor(config);
    final result = await _request(server, 'tools/call', {'name': tool, 'arguments': arguments}, timeout);
    final content = asMapList(result['content']);
    final text = [
      for (final block in content)
        if (block['text'] is String) block['text']! as String else jsonEncode(block),
    ].join('\n');
    final structured = result['structuredContent'];
    final answer = text.isEmpty && structured != null ? jsonEncode(structured) : text;
    if (result['isError'] == true) throw McpException(answer.isEmpty ? 'the tool failed' : answer, McpFailure.server);
    return answer;
  }

  /// The server an AI Agent tool's setting names: a saved "MCP server"
  /// credential, a URL, or a command run in Ubuntu.
  Future<JsonMap> serverFor(String config) async {
    final text = config.trim();
    if (text.isEmpty) throw const McpException('this tool has no MCP server');
    final saved = await credentials.store.byName(text);
    if (saved != null && saved.type == 'mcpServer') return {'transport': 'saved', 'credential': text};
    if (text.startsWith('http://') || text.startsWith('https://')) return {'transport': 'http', 'url': text};
    return {'transport': 'stdio', 'command': text};
  }

  /// One request on [server]'s session, reopening it once if the server forgot it.
  Future<JsonMap> _request(JsonMap server, String method, JsonMap params, Duration timeout) async {
    final key = jsonEncode(server);
    for (var attempt = 0; ; attempt++) {
      final session = await _session(key, server, timeout);
      try {
        return await session.request(method, params, timeout);
      } on McpException catch (e) {
        if (e.kind == McpFailure.server) rethrow;
        await _drop(key);
        if (e.kind != McpFailure.sessionExpired || attempt > 0) rethrow;
      }
    }
  }

  /// Closes every open session (the app is shutting down, or a test is done).
  Future<void> closeAll() async {
    for (final key in _sessions.keys.toList()) {
      await _drop(key);
    }
  }

  Future<McpSession> _session(String key, JsonMap server, Duration timeout) async {
    final open = _sessions[key];
    if (open != null) return (await open)..touch();
    final opening = _open(key, server, timeout);
    _sessions[key] = opening;
    try {
      return await opening;
    } on Object {
      // A failed start is not kept, so the next call tries again.
      if (identical(_sessions[key], opening)) _sessions.remove(key)?.ignore();
      rethrow;
    }
  }

  Future<McpSession> _open(String key, JsonMap server, Duration timeout) async {
    final McpTransport transport = switch (asString(server['transport'])) {
      'http' => await _http(server),
      'stdio' => await StdioTransport.start(linux, asString(server['command'])),
      'saved' => await _saved(asString(server['credential'])),
      final other => throw McpException('unknown MCP transport "$other"', McpFailure.transport),
    };
    final session = McpSession(transport, idle: idle, onIdle: () => unawaited(_drop(key)));
    try {
      // Starting a server with npx may download it first.
      await session.initialize(timeout < const Duration(minutes: 2) ? const Duration(minutes: 2) : timeout);
    } on McpException {
      await transport.close();
      rethrow;
    }
    return session;
  }

  /// A saved "MCP server" credential: a web server with its sign-in header, or a command with its environment.
  Future<McpTransport> _saved(String name) async {
    if (name.isEmpty) throw const McpException('choose a saved MCP server');
    final ResolvedCredential saved;
    try {
      saved = await credentials.open(name);
    } on CredentialException catch (e) {
      throw McpException(e.message);
    }
    if (saved.credential.type != 'mcpServer') throw McpException('“$name” is not an MCP server credential');
    final v = saved.values;
    final url = (v['url'] ?? '').trim();
    final command = (v['command'] ?? '').trim();
    if (url.isNotEmpty) {
      final value = v['headerValue'] ?? '';
      final header = (v['headerName'] ?? '').trim();
      return HttpTransport(
        _client,
        Uri.parse(url),
        headers: {if (value.isNotEmpty) (header.isEmpty ? 'Authorization' : header): value},
        secrets: saved.secrets,
      );
    }
    if (command.isEmpty) throw McpException('“$name” has neither a URL nor a command');
    return StdioTransport.start(linux, command, env: parseEnv(v['env'] ?? ''));
  }

  /// `KEY=value; OTHER=value` (or one per line) as a map; other text is skipped.
  static Map<String, String> parseEnv(String text) {
    final out = <String, String>{};
    for (final part in text.split(RegExp(r'[;\n]'))) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      final key = part.substring(0, eq).trim();
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) continue;
      out[key] = part.substring(eq + 1).trim();
    }
    return out;
  }

  Future<HttpTransport> _http(JsonMap server) async {
    final url = asString(server['url']);
    var headers = <String, String>{};
    var secrets = const <String>[];
    final credential = asString(server['credential']);
    if (credential.isNotEmpty) {
      try {
        final (resolved, found) = await credentials.resolve({
          'credential': credential,
          'auth': true,
          'url': url,
          'headers': const <String, String>{},
        });
        headers = asMap(resolved['headers']).map((k, v) => MapEntry(k, asString(v)));
        secrets = found;
      } on CredentialException catch (e) {
        throw McpException(e.message, McpFailure.transport);
      }
    }
    return HttpTransport(_client, Uri.parse(url), headers: headers, secrets: secrets);
  }

  Future<void> _drop(String key) async {
    final session = _sessions.remove(key);
    if (session == null) return;
    try {
      await (await session).close();
    } on Object {
      // Already gone.
    }
  }
}

enum McpFailure {
  /// The server answered the request with a JSON-RPC error; other calls may still work.
  server,

  /// The server could not be reached, stopped, or did not answer in time.
  transport,

  /// A web server no longer knows the session (HTTP 404); a new one may work.
  sessionExpired,
}

class McpException implements Exception {
  const McpException(this.message, [this.kind = McpFailure.transport]);

  final String message;
  final McpFailure kind;

  @override
  String toString() => message;
}

/// One initialized connection to a server.
class McpSession {
  McpSession(this.transport, {required this.idle, required this.onIdle});

  final McpTransport transport;

  /// How long the session stays open after its last use.
  final Duration idle;

  /// Closes the session once it has been idle for [idle].
  final void Function() onIdle;
  Timer? _timer;

  Future<void> initialize(Duration timeout) async {
    final result = await transport.request('initialize', {
      'protocolVersion': McpClient.protocolVersion,
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'FlowDroid', 'version': '1.0.0'},
    }, timeout);
    transport.protocolVersion = asString(result['protocolVersion'], McpClient.protocolVersion);
    await transport.notify('notifications/initialized');
    touch();
  }

  Future<JsonMap> request(String method, JsonMap params, Duration timeout) async {
    _timer?.cancel();
    try {
      return await transport.request(method, params, timeout);
    } finally {
      touch();
    }
  }

  void touch() {
    _timer?.cancel();
    _timer = Timer(idle, onIdle);
  }

  Future<void> close() async {
    _timer?.cancel();
    await transport.close();
  }
}

/// How JSON-RPC messages reach a server.
abstract class McpTransport {
  /// Set after `initialize`; web servers expect it on every later request.
  String? protocolVersion;

  /// Sends a request and returns its `result`; a JSON-RPC `error` throws [McpFailure.server].
  Future<JsonMap> request(String method, JsonMap params, Duration timeout);

  Future<void> notify(String method, [JsonMap? params]);

  Future<void> close();
}

/// The `result` of a JSON-RPC response, or its error as an [McpException].
JsonMap _resultOf(JsonMap message) {
  if (message['error'] != null) {
    final error = asMap(message['error']);
    final text = asString(error['message'], 'error ${asInt(error['code'])}');
    throw McpException(text, McpFailure.server);
  }
  return asMap(message['result']);
}

/// Streamable HTTP: each message is a POST; the answer is JSON or a short SSE stream.
class HttpTransport extends McpTransport {
  HttpTransport(this._client, this.url, {this.headers = const {}, this.secrets = const []});

  final http.Client _client;
  final Uri url;
  final Map<String, String> headers;

  /// Credential values, scrubbed from error messages.
  final List<String> secrets;
  String? sessionId;
  var _nextId = 1;

  @override
  Future<JsonMap> request(String method, JsonMap params, Duration timeout) async {
    final id = _nextId++;
    final message = await _post({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}, id, timeout);
    return _resultOf(message!);
  }

  @override
  Future<void> notify(String method, [JsonMap? params]) async {
    await _post({'jsonrpc': '2.0', 'method': method, 'params': ?params}, null, const Duration(seconds: 30));
  }

  @override
  Future<void> close() async {
    final id = sessionId;
    if (id == null) return;
    // Ends the session on the server; servers that don't support it answer 405, which is fine.
    try {
      await _client.delete(url, headers: {...headers, 'Mcp-Session-Id': id}).timeout(const Duration(seconds: 5));
    } on Object {
      // The session ends on its own.
    }
  }

  /// Posts [body]; for a request, returns the response message with [id].
  Future<JsonMap?> _post(JsonMap body, int? id, Duration timeout) async {
    final request = http.Request('POST', url)
      ..headers.addAll({
        ...headers,
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'Mcp-Session-Id': ?sessionId,
        'MCP-Protocol-Version': ?protocolVersion,
      })
      ..body = jsonEncode(body);
    try {
      final response = await _client.send(request).timeout(timeout);
      final session = response.headers['mcp-session-id'];
      if (session != null && session.isNotEmpty) sessionId = session;
      if (response.statusCode == 404 && request.headers.containsKey('Mcp-Session-Id')) {
        await response.stream.drain<void>();
        throw const McpException('the MCP server ended the session', McpFailure.sessionExpired);
      }
      if (response.statusCode >= 400) {
        final text = await response.stream.bytesToString().timeout(timeout, onTimeout: () => '');
        throw McpException('MCP server error ${response.statusCode}: ${_scrub(_short(text))}');
      }
      if (id == null) {
        await response.stream.drain<void>();
        return null;
      }
      final type = response.headers['content-type'] ?? '';
      if (type.contains('text/event-stream')) return await _fromEvents(response.stream, id).timeout(timeout);
      final text = await response.stream.bytesToString().timeout(timeout);
      return _matching(text, id) ?? (throw const McpException('the MCP server sent no answer'));
    } on TimeoutException {
      throw McpException('the MCP server did not answer within ${timeout.inSeconds} s');
    } on McpException {
      rethrow;
    } on Exception catch (e) {
      throw McpException('could not reach the MCP server: ${_scrub('$e')}');
    }
  }

  /// The response with [id] in a JSON body: one message or a batch.
  static JsonMap? _matching(String text, int id) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw McpException('the MCP server sent something that is not JSON: ${_short(text)}');
    }
    final messages = decoded is List ? asMapList(decoded) : [asMap(decoded)];
    return messages.where((m) => m['id'] == id && m['method'] == null).firstOrNull;
  }

  /// Reads server-sent events until the response with [id] arrives.
  static Future<JsonMap> _fromEvents(Stream<List<int>> stream, int id) async {
    final data = StringBuffer();
    await for (final line in stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
        continue;
      }
      if (line.isNotEmpty || data.isEmpty) continue;
      final event = data.toString();
      data.clear();
      try {
        final message = asMap(jsonDecode(event));
        if (message['id'] == id && message['method'] == null) return message;
      } on FormatException {
        // Not a JSON-RPC message; keep reading.
      }
    }
    if (data.isNotEmpty) {
      try {
        final message = asMap(jsonDecode(data.toString()));
        if (message['id'] == id && message['method'] == null) return message;
      } on FormatException {
        // Fall through.
      }
    }
    throw const McpException('the MCP server closed the stream without an answer');
  }

  String _scrub(String text) => secrets.fold(text, (t, s) => t.replaceAll(s, '•••'));

  static String _short(String text) {
    final t = text.trim();
    return t.length > 300 ? '${t.substring(0, 300)}…' : t;
  }
}

/// stdio: a command in Ubuntu, one JSON-RPC message per line on its stdin and stdout.
class StdioTransport extends McpTransport {
  StdioTransport(this._process) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLine, onError: (Object _) {});
    _process.stderr.transform(utf8.decoder).listen((text) {
      _stderr.write(text);
      final s = _stderr.toString();
      if (s.length > 8192) {
        _stderr
          ..clear()
          ..write(s.substring(s.length - 4096));
      }
    }, onError: (Object _) {});
    unawaited(_process.exitCode.then(_onExit));
  }

  static const _path = r'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"';

  static Future<StdioTransport> start(LinuxRuntime linux, String command, {Map<String, String> env = const {}}) async {
    if (!await linux.ubuntuInstalled) {
      throw const McpException(
        'MCP servers with a command run in FlowDroid’s Ubuntu: install it in Settings → Terminal',
      );
    }
    final exports = [for (final e in env.entries) 'export ${e.key}=${_quote(e.value)};'].join(' ');
    try {
      return StdioTransport(await linux.startUbuntu('$_path; $exports exec $command'));
    } on LinuxException catch (e) {
      throw McpException(e.message);
    } on ProcessException catch (e) {
      throw McpException('could not start the MCP server: ${e.message}');
    }
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  final Process _process;
  final _pending = <int, Completer<JsonMap>>{};
  final _stderr = StringBuffer();
  var _nextId = 1;
  String? _exited;

  @override
  Future<JsonMap> request(String method, JsonMap params, Duration timeout) async {
    final exited = _exited;
    if (exited != null) throw McpException(exited);
    final id = _nextId++;
    final answer = Completer<JsonMap>();
    _pending[id] = answer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    try {
      return _resultOf(await answer.future.timeout(timeout));
    } on TimeoutException {
      throw McpException('the MCP server did not answer within ${timeout.inSeconds} s');
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> notify(String method, [JsonMap? params]) async {
    _send({'jsonrpc': '2.0', 'method': method, 'params': ?params});
  }

  @override
  Future<void> close() async {
    _exited ??= 'the MCP server was closed';
    _process.kill(ProcessSignal.sigkill);
  }

  void _send(JsonMap message) {
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on Object {
      // The process is gone; _onExit reports it.
    }
  }

  void _onLine(String line) {
    final JsonMap message;
    try {
      message = asMap(jsonDecode(line));
    } on FormatException {
      return; // A server that logs to stdout; not a message.
    }
    final method = message['method'];
    final id = message['id'];
    if (method == null) {
      if (id is int) _pending[id]?.complete(message);
      return;
    }
    // A request from the server: answer pings, decline what FlowDroid doesn't offer.
    if (id == null) return;
    _send(
      method == 'ping'
          ? {'jsonrpc': '2.0', 'id': id, 'result': <String, Object?>{}}
          : {
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32601, 'message': 'FlowDroid does not support $method'},
            },
    );
  }

  void _onExit(int code) {
    final last = _stderr.toString().trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
    final message = code == 127
        ? 'the MCP server command was not found in Ubuntu${last == null ? '' : ': $last'}'
        : 'the MCP server stopped (exit $code)${last == null ? '' : ': $last'}';
    _exited ??= message;
    for (final answer in _pending.values) {
      if (!answer.isCompleted) answer.completeError(McpException(_exited!));
    }
    _pending.clear();
  }
}
