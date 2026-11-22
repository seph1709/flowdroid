import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
class WebhookServer {
  WebhookServer({required this.repository, required this.runner, this.credentials, this.port = defaultPort});

  static const defaultPort = 5678;
  static const _prefix = '/webhook/';

  final Repository repository;
  final WorkflowRunner runner;

  /// For triggers that require a key (a `webhookAuth` credential).
  final CredentialStore? credentials;
  final int port;
  HttpServer? _server;

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server = server;
    unawaited(server.forEach(_handle));
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
  Future<(bool, String?)> _authorized(WorkflowNode trigger, HttpRequest request) async {
    final name = asString(trigger.params['credential']);
    if (name.isEmpty) return (true, null);
    final credential = await credentials?.byName(name);
    final expected = credential?.values['value'] ?? '';
    if (credential == null || credential.type != 'webhookAuth' || expected.isEmpty) return (false, null);
    final header = (credential.values['headerName'] ?? '').trim();
    final headerName = (header.isEmpty ? 'X-FlowDroid-Key' : header).toLowerCase();
    final given = request.headers.value(headerName) ?? '';
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
    if (!path.startsWith(_prefix)) return _reply(request.response, 404, {'error': 'not found'});
    final hookPath = path.substring(_prefix.length);
    final matching = await _matching(hookPath, request.method);
    if (matching.isEmpty) return _reply(request.response, 404, {'error': 'no active workflow listens on $hookPath'});
    final keyHeaders = <String>{};
    final targets = <(Workflow, WorkflowNode)>[];
    for (final target in matching) {
      final (ok, header) = await _authorized(target.$2, request);
      if (!ok) continue;
      targets.add(target);
      if (header != null) keyHeaders.add(header);
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
    response.headers.contentType = ContentType.parse(contentType);
    response.write(body is String && !contentType.contains('json') ? body : jsonEncode(body));
    await response.close();
  }
}
