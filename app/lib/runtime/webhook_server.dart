import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/execution_state.dart';
import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../data/credentials.dart';
import '../data/repository.dart';
import 'runner.dart';

/// An HTTP server on the device that starts workflows with a Webhook Trigger.
///
/// `POST http://<phone-ip>:<port>/webhook/<path>` runs every active workflow
/// whose trigger has that path and method. The response comes from a
/// "Respond to Webhook" node if one runs, otherwise it is the run's summary.
///
/// `http://<phone-ip>:<port>/mcp` is an MCP server (Streamable HTTP, JSON
/// answers): every active workflow with an MCP Tool Trigger is a tool, and
/// calling it runs the workflow with the tool's arguments as its item.
class WebhookServer {
  WebhookServer({required this.repository, required this.runner, this.credentials, this.port = defaultPort});

  static const defaultPort = 5678;
  static const _prefix = '/webhook/';

  /// Where FlowDroid's MCP server answers.
  static const mcpPath = '/mcp';

  /// MCP protocol versions the server speaks; it answers with the client's if listed.
  static const _mcpVersions = {'2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'};
  static final _toolName = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final Repository repository;
  final WorkflowRunner runner;

  /// For triggers that require a key (a `webhookAuth` credential).
  final CredentialStore? credentials;
  final int port;
  HttpServer? _server;

  bool get isRunning => _server != null;

  /// The port it listens on: [port], or the free one the system chose when [port] is 0 (tests).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    // Each request on its own: a long workflow must not hold up the others, and one
    // request that fails must not stop the server (forEach would end at its error).
    server.listen((request) => unawaited(_handleSafely(request)));
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handle(request);
    } on Object catch (e) {
      // Bad input (an invalid %-escape in the address, a body that is not UTF-8) is the
      // caller's mistake; anything else is ours.
      final bad = e is FormatException || e is ArgumentError;
      try {
        await _reply(request.response, bad ? 400 : 500, {'error': bad ? 'bad request: $e' : 'FlowDroid failed: $e'});
      } on Object catch (_) {
        // The answer was already sent, or the caller is gone.
      }
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Addresses other devices on the network can reach, e.g. `http://192.168.1.5:5678`.
  Future<List<String>> addresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in interfaces)
        for (final a in i.addresses)
          if (!a.isLoopback) 'http://${a.address}:$port',
    ];
  }

  /// Whether [request] carries the key [trigger] asks for; also the header that held it.
  Future<(bool, String?)> _authorized(WorkflowNode trigger, HttpRequest request) =>
      _keyMatches(trigger, request.headers.value);

  Future<(bool, String?)> _keyMatches(WorkflowNode trigger, String? Function(String name) headerValue) async {
    final name = asString(trigger.params['credential']);
    if (name.isEmpty) return (true, null);
    final credential = await credentials?.byName(name);
    final expected = credential?.values['value'] ?? '';
    if (credential == null || credential.type != 'webhookAuth' || expected.isEmpty) return (false, null);
    final header = (credential.values['headerName'] ?? '').trim();
    final headerName = (header.isEmpty ? 'X-FlowDroid-Key' : header).toLowerCase();
    final given = headerValue(headerName) ?? '';
    return (_sameText(given, expected), headerName);
  }

  /// Compares in constant time, so the key can't be guessed from response times.
  static bool _sameText(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path == mcpPath) return _mcp(request);
    if (!path.startsWith(_prefix)) return _reply(request.response, 404, {'error': 'not found'});
    final hookPath = path.substring(_prefix.length);
    final matching = await _matching(hookPath, request.method);
    if (matching.isEmpty) return _reply(request.response, 404, {'error': 'no active workflow listens on $hookPath'});
    // A web page open in a browser can POST here too (browsers allow simple cross-site
    // posts). Servers, apps and curl send no Origin, so only keyed triggers accept one.
    final origin = request.headers.value('origin');
    final fromWebPage = origin != null && !_localOrigin(origin);
    var blocked = false;
    final keyHeaders = <String>{};
    final targets = <(Workflow, WorkflowNode)>[];
    for (final target in matching) {
      final (ok, header) = await _authorized(target.$2, request);
      if (!ok) continue;
      if (header == null && fromWebPage) {
        blocked = true;
        continue;
      }
      targets.add(target);
      if (header != null) keyHeaders.add(header);
    }
    if (targets.isEmpty && blocked) {
      return _reply(request.response, 403, {'error': 'web pages may only call webhooks that have a key'});
    }
    if (targets.isEmpty) return _reply(request.response, 401, {'error': 'missing or wrong key'});

    final item = await _itemFrom(request, hookPath);
    // Never keep the key in run history.
    final headers = item['headers'];
    if (headers is Map) headers.removeWhere((name, _) => keyHeaders.contains('$name'.toLowerCase()));
    var responded = false;
    Future<void> respond(int status, String contentType, Object? body) async {
      if (responded) return;
      responded = true;
      await _reply(request.response, status, body, contentType: contentType);
    }

    final summaries = <JsonMap>[];
    for (final (workflow, trigger) in targets) {
      final record = await runner.run(
        workflow,
        triggerNodeId: trigger.id,
        mode: TriggerMode.webhook,
        items: [item],
        respond: respond,
      );
      summaries.add({
        'workflow': workflow.name,
        'execution': record.id,
        'status': record.status.name,
        'error': record.error,
      });
    }
    await respond(200, 'application/json', summaries.length == 1 ? summaries.first : summaries);
  }

  Future<List<(Workflow, WorkflowNode)>> _matching(String hookPath, String method) async {
    final workflows = await repository.workflows();
    return [
      for (final wf in workflows.where((w) => w.active))
        for (final trigger in wf.nodesOfType('trigger.webhook'))
          if (asString(trigger.params['path'], 'my-hook') == hookPath &&
              {'ANY', method}.contains(asString(trigger.params['method'], 'POST').toUpperCase()))
            (wf, trigger),
    ];
  }

  // ---------------------------------------------------------------- MCP server

  Future<void> _mcp(HttpRequest request) async {
    final response = request.response;
    // A web page must not reach the phone's workflows through the browser (DNS rebinding).
    final origin = request.headers.value('origin');
    if (origin != null && !_localOrigin(origin)) return _reply(response, 403, {'error': 'origin not allowed'});
    if (request.method != 'POST') {
      response.headers.set('Allow', 'POST');
      return _reply(response, 405, {'error': 'FlowDroid’s MCP server answers POST requests'});
    }
    final Object? body;
    try {
      body = jsonDecode(await utf8.decodeStream(request));
    } on FormatException {
      return _reply(response, 400, _rpcError(null, -32700, 'Parse error'));
    }
    final tools = await mcpTools(request.headers.value);
    final batch = body is List;
    final answers = <JsonMap>[];
    for (final message in batch ? asList(body) : [body]) {
      final answer = await _answer(asMap(message), tools);
      if (answer != null) answers.add(answer);
    }
    if (answers.isEmpty) {
      response.statusCode = 202;
      return response.close();
    }
    return _reply(response, 200, batch ? answers : answers.single);
  }

  static bool _localOrigin(String origin) {
    final host = Uri.tryParse(origin)?.host ?? '';
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  /// The tools a caller with these request headers may use: one per active
  /// workflow with an MCP Tool Trigger whose key (if it asks for one) was sent.
  Future<List<McpTool>> mcpTools(String? Function(String name) header) async {
    final tools = <McpTool>[];
    final names = <String>{};
    for (final wf in (await repository.workflows()).where((w) => w.active)) {
      for (final trigger in wf.nodesOfType('trigger.mcp')) {
        final name = asString(trigger.params['name'], 'my_tool');
        if (!_toolName.hasMatch(name) || names.contains(name)) continue;
        if (!(await _keyMatches(trigger, header)).$1) continue;
        names.add(name);
        tools.add(
          McpTool(wf, trigger, name, asString(trigger.params['description']), _schema(trigger.params['inputSchema'])),
        );
      }
    }
    return tools;
  }

  /// The trigger's JSON Schema for its arguments; an object schema, or one that accepts any object.
  static JsonMap _schema(Object? value) {
    Object? schema = value;
    if (value is String) {
      try {
        schema = jsonDecode(value.trim().isEmpty ? '{}' : value);
      } on FormatException {
        schema = null;
      }
    }
    final map = asMap(schema);
    return map['type'] == 'object' ? map : {'type': 'object', 'properties': <String, Object?>{}};
  }

  Future<JsonMap?> _answer(JsonMap message, List<McpTool> tools) async {
    final id = message['id'];
    final method = message['method'];
    // Notifications and the client's own answers need no reply.
    if (method is! String || id == null) return null;
    final params = asMap(message['params']);
    JsonMap ok(JsonMap result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    switch (method) {
      case 'initialize':
        final asked = asString(params['protocolVersion']);
        return ok({
          'protocolVersion': _mcpVersions.contains(asked) ? asked : '2025-06-18',
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'FlowDroid', 'version': '1.0.0'},
          'instructions': 'Each tool runs a FlowDroid workflow on the phone and returns what its last step produced.',
        });
      case 'ping':
        return ok({});
      case 'tools/list':
        return ok({
          'tools': [
            for (final t in tools)
              {
                'name': t.name,
                if (t.description.isNotEmpty) 'description': t.description,
                'inputSchema': t.inputSchema,
              },
          ],
        });
      case 'tools/call':
        final name = asString(params['name']);
        final tool = tools.where((t) => t.name == name).firstOrNull;
        if (tool == null) return _rpcError(id, -32602, 'Unknown tool: $name');
        return ok(await _callTool(tool, asMap(params['arguments'])));
      default:
        return _rpcError(id, -32601, 'Method not found: $method');
    }
  }

  /// Runs the tool's workflow; its answer is what a Respond to Webhook node sent, or the last step's items.
  Future<JsonMap> _callTool(McpTool tool, JsonMap arguments) async {
    Object? responded;
    var hasResponse = false;
    final record = await runner.run(
      tool.workflow,
      triggerNodeId: tool.trigger.id,
      mode: TriggerMode.mcp,
      items: [arguments],
      respond: (status, contentType, body) async {
        if (hasResponse) return;
        hasResponse = true;
        responded = body;
      },
    );
    if (record.status == ExecutionStatus.error) {
      return {
        'content': [
          {'type': 'text', 'text': '“${tool.workflow.name}” failed: ${record.error ?? 'unknown error'}'},
        ],
        'isError': true,
      };
    }
    final Object? answer;
    if (hasResponse) {
      answer = responded;
    } else {
      final items = record.runs.lastOrNull?.outputs.expand((list) => list).toList() ?? const <JsonMap>[];
      answer = items.length == 1 ? items.single : items;
    }
    return {
      'content': [
        {'type': 'text', 'text': answer is String ? answer : jsonEncode(answer)},
      ],
    };
  }

  static JsonMap _rpcError(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  static Future<JsonMap> _itemFrom(HttpRequest request, String hookPath) async {
    final text = await utf8.decodeStream(request);
    Object? body = text;
    if (request.headers.contentType?.mimeType == 'application/json' && text.isNotEmpty) {
      try {
        body = jsonDecode(text);
      } on FormatException {
        body = text;
      }
    }
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(', '));
    return {
      'method': request.method,
      'path': hookPath,
      'headers': headers,
      'query': request.uri.queryParameters,
      'body': body,
    };
  }

  static Future<void> _reply(
    HttpResponse response,
    int status,
    Object? body, {
    String contentType = 'application/json',
  }) async {
    response.statusCode = status;
    final type = ContentType.parse(contentType);
    // Without a charset the response is written as Latin-1, which fails on other text.
    response.headers.contentType = type.charset == null
        ? ContentType(type.primaryType, type.subType, charset: 'utf-8', parameters: type.parameters)
        : type;
    response.write(body is String && !contentType.contains('json') ? body : jsonEncode(body));
    await response.close();
  }
}

/// A workflow offered as a tool on FlowDroid's MCP server.
class McpTool {
  const McpTool(this.workflow, this.trigger, this.name, this.description, this.inputSchema);

  final Workflow workflow;
  final WorkflowNode trigger;
  final String name;
  final String description;
  final JsonMap inputSchema;
}
