import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'linux/linux_runtime.dart';
import 'browser/browser_driver.dart';
import 'mcp_client.dart';
import 'table_effect.dart';

/// Runs another workflow with [items] and returns its output.
typedef WorkflowCaller = Future<List<JsonMap>> Function(String workflowId, List<JsonMap> items);

/// Carries out the tool calls the AI Agent asks for and reports each result as text.
class AgentTools {
  AgentTools({
    required this.linux,
    required this.tables,
    required this.callWorkflow,
    this.mcp,
    this.browser,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Longest result handed back to the model.
  static const maxResult = 20000;

  final LinuxRuntime linux;
  final TableEffect tables;
  final WorkflowCaller callWorkflow;

  /// For `mcp` tools: a server's tool, called with Claude's input.
  final McpClient? mcp;

  /// For `browser` tools: the phone's in-app browser.
  final BrowserDriver? browser;
  final http.Client _client;

  Future<JsonMap> call(JsonMap effect) async {
    final results = <JsonMap>[];
    for (final call in asMapList(effect['calls'])) {
      try {
        results.add({'content': _cut(await _run(call)), 'isError': false});
      } on Exception catch (e) {
        results.add({'content': _cut('$e'), 'isError': true});
      }
    }
    return {'results': results};
  }

  Future<String> _run(JsonMap call) async {
    final input = asMap(call['input']);
    final config = asString(call['config']);
    switch (asString(call['kind'])) {
      case 'http':
        final url = asString(input['url']);
        if (config.isNotEmpty && !url.startsWith(config)) throw ToolException('the URL must start with $config');
        final uri = Uri.tryParse(url);
        if (uri == null || !uri.hasScheme) throw ToolException('“$url” is not a URL');
        final request = http.Request(asString(input['method'], 'GET').toUpperCase(), uri);
        final body = input['body'];
        if (body != null) {
          request.body = body is String ? body : jsonEncode(body);
          request.headers['Content-Type'] = 'application/json';
        }
        final response = await http.Response.fromStream(
          await _client.send(request).timeout(const Duration(seconds: 30)),
        );
        return 'HTTP ${response.statusCode}\n${response.body}';
      case 'command':
        final r = await linux.run(
          asString(input['command']),
          target: config == 'phone' ? LinuxTarget.phone : LinuxTarget.ubuntu,
          timeout: const Duration(minutes: 2),
        );
        if (r.error != null) throw ToolException(r.error!);
        return [
          if (r.stdout.isNotEmpty) r.stdout,
          if (r.stderr.isNotEmpty) 'stderr:\n${r.stderr}',
          'exit code ${r.exitCode}',
        ].join('\n');
      case 'browser':
        final driver = browser;
        if (driver == null) throw const ToolException('the browser is not available here');
        try {
          return await driver.agent(input, config);
        } on BrowserException catch (e) {
          throw ToolException(e.message);
        }
      case 'mcp':
        final client = mcp;
        if (client == null) throw const ToolException('MCP servers are not available here');
        return client.callTool(config, asString(call['tool']), input, const Duration(minutes: 2));
      case 'workflow':
        if (config.isEmpty) throw const ToolException('this tool has no workflow chosen');
        final input0 = input['input'];
        final output = await callWorkflow(config, [input0 is Map ? asMap(input0) : <String, Object?>{}]);
        return jsonEncode(output);
      case 'table':
        if (config.isEmpty) throw const ToolException('this tool has no table name');
        final result = await tables({
          'table': config,
          'operation': asString(input['operation'], 'find'),
          'requests': [
            {'where': asMap(input['where']), 'row': asMap(input['row']), 'limit': 100},
          ],
        });
        if (result['error'] != null) throw ToolException(asString(result['error']));
        return jsonEncode(result['rows']);
      default:
        throw ToolException('there is no tool named “${asString(call['name'])}”');
    }
  }

  static String _cut(String text) =>
      text.length > maxResult ? '${text.substring(0, maxResult)}\n… (cut at $maxResult characters)' : text;
}

class ToolException implements Exception {
  const ToolException(this.message);

  final String message;

  @override
  String toString() => message;
}
