import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/app_services.dart';
import 'package:flowdroid/assistant/assistant_engine.dart';
import 'package:flowdroid/assistant/cli_assistant.dart';
import 'package:flowdroid/assistant/workflow_tools.dart';
import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flowdroid/ui/editor/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

Future<EditorController> editor({bool approve = true}) async {
  final dir = await Directory.systemTemp.createTemp('flowdroid_assistant');
  final services = AppServices(
    core: core,
    repository: await tempRepository(),
    credentials: CredentialStore(),
    linux: LinuxRuntime(dir),
    dataDir: dir,
    effects: FakeEffects(),
  );
  final wf = Workflow(
    id: 'wf',
    name: 'Test',
    nodes: [WorkflowNode(id: 'start', name: 'Start', type: 'trigger.manual')],
  );
  return EditorController(services: services, workflow: wf);
}

WorkflowTools toolsFor(EditorController c, {bool approve = true}) =>
    WorkflowTools(controller: c, approveRun: (_) async => approve);

/// A saved credential without secure storage.
class _Credentials extends CredentialStore {
  _Credentials(this.list);

  final List<Credential> list;

  @override
  Future<List<Credential>> all() async => list;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds, edits and connects steps; one reply undoes as one step', () async {
    final c = await editor();
    final tools = toolsFor(c)..group = 'reply-1';
    final add = await tools.call('add_node', {
      'type': 'core.set',
      'name': 'Make greeting',
      'after': 'Start',
      'params': {
        'fields': [
          {'name': 'greeting', 'value': 'hi {{ \$json.name }}'},
        ],
      },
    });
    expect(add.isError, isFalse, reason: add.text);
    expect(add.changed, isTrue);
    final set = c.workflow.nodes.firstWhere((n) => n.name == 'Make greeting');
    expect(c.workflow.connections.single.to, set.id);

    final bad = await tools.call('update_node', {
      'node': 'Make greeting',
      'params': {'nope': 1},
    });
    expect(bad.isError, isTrue);
    expect(bad.text, contains('has no parameter nope'));

    final upd = await tools.call('update_node', {
      'node': 'make greeting',
      'params': {'keepOnlySet': true},
    });
    expect(upd.isError, isFalse, reason: upd.text);
    expect(set.params['keepOnlySet'], isTrue);

    await tools.call('add_node', {'type': 'android.vibrate', 'name': 'Buzz'});
    final conn = await tools.call('connect', {'from': 'Make greeting', 'to': 'Buzz'});
    expect(conn.isError, isFalse, reason: conn.text);
    final toTrigger = await tools.call('connect', {'from': 'Buzz', 'to': 'Start'});
    expect(toTrigger.text, contains('trigger'));

    final wf = asMap(jsonDecode((await tools.call('get_workflow', {})).text));
    expect(asList(wf['steps']).length, 3);
    expect(asList(wf['connections']).length, 2);

    // Everything above was one reply: a single undo goes back to the start.
    c.undo();
    expect(c.workflow.nodes.map((n) => n.name), ['Start']);
  });

  test('describes step types with parameter shapes', () async {
    final c = await editor();
    final out = await toolsFor(c).call('describe_node_types', {
      'types': ['core.if', 'nope.nothing'],
    });
    final list = asMapList(jsonDecode(out.text));
    final params = asMapList(list.first['params']);
    expect(params.firstWhere((p) => p['key'] == 'conditions')['shape'], contains('"op"'));
    expect(list.last['error'], contains('no such step type'));
    final all = await toolsFor(c).call('list_node_types', {});
    expect(all.text, contains('## trigger'));
  });

  test('runs the workflow only when the person approves', () async {
    final c = await editor();
    final declined = await toolsFor(c, approve: false).call('run_workflow', {});
    expect(declined.isError, isTrue);
    expect(c.lastExecution, isNull);
    final tools = toolsFor(c);
    await tools.call('add_node', {
      'type': 'core.set',
      'name': 'Broken',
      'after': 'Start',
      'params': {
        'fields': [
          {'name': '', 'value': 'x'},
        ],
      },
    });
    final ran = asMap(jsonDecode((await tools.call('run_workflow', {})).text));
    expect(ran['status'], 'error');
    final broken = asMapList(ran['steps']).firstWhere((s) => s['step'] == 'Broken');
    expect(broken['error'], contains('field name is required'));
  });

  test('a closed editor refuses tool calls', () async {
    final c = await editor();
    final tools = toolsFor(c)..closed = true;
    final r = await tools.call('add_node', {'type': 'android.vibrate', 'name': 'Buzz'});
    expect(r.isError, isTrue);
    expect(c.workflow.nodes.length, 1);
  });

  test('MCP server answers initialize, tools/list and tools/call', () async {
    final c = await editor();
    final server = McpToolServer()..tools = toolsFor(c);
    final actions = <AssistantEvent>[];
    server.emit = actions.add;
    final init = await server.answer({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18'},
    });
    expect(asMap(init!['result'])['protocolVersion'], '2025-06-18');
    expect(await server.answer({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
    final list = await server.answer({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    expect(asMapList(asMap(list!['result'])['tools']).map((t) => t['name']), contains('add_node'));
    final call = await server.answer({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'add_node',
        'arguments': {'type': 'android.vibrate', 'name': 'Buzz', 'after': 'Start'},
      },
    });
    expect(asMap(call!['result'])['isError'], isFalse);
    expect(c.workflow.nodes.length, 2);
    expect((actions.single as AssistantAction).summary, 'Added “Buzz”');
  });

  test('MCP server over HTTP needs the token', () async {
    // The test binding answers every real HTTP request with 400; this one must be real.
    HttpOverrides.global = null;
    final server = McpToolServer();
    final url = await server.start();
    final denied = await http.post(Uri.parse(url), body: '{}');
    expect(denied.statusCode, 401);
    final ok = await http.post(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${server.token}'},
      body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}),
    );
    expect(asMap(jsonDecode(ok.body))['id'], 1);

    // The bridge script, as Claude Code or Codex start it: JSON-RPC lines in, answers out.
    final dir = await Directory.systemTemp.createTemp('bridge');
    final script = File('${dir.path}/mcp-bridge.sh')..writeAsStringSync(mcpBridgeScript);
    final p = await Process.start('bash', [script.path, url, server.token]);
    p.stdin
      ..writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18'},
        }),
      )
      ..writeln(jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}))
      ..writeln(jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}));
    await p.stdin.close();
    final lines = await p.stdout.transform(utf8.decoder).transform(const LineSplitter()).toList();
    expect(lines.map((l) => asMap(jsonDecode(l))['id']), [1, 2]);
    await server.close();
  });

  test('Claude API loop: tool calls, results in one message, then the answer', () async {
    final c = await editor();
    final requests = <JsonMap>[];
    final client = MockClient((r) async {
      final body = asMap(jsonDecode(r.body));
      requests.add(body);
      expect(r.headers['anthropic-version'], '2026-10-21');
      expect(r.headers['x-api-key'], 'k');
      final reply = requests.length == 1
          ? {
              'stop_reason': 'tool_use',
              'content': [
                {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
                {'type': 'text', 'text': 'Adding a buzz.'},
                {
                  'type': 'tool_use',
                  'id': 't1',
                  'name': 'add_node',
                  'input': {'type': 'android.vibrate', 'name': 'Buzz', 'after': 'Start'},
                },
                {'type': 'tool_use', 'id': 't2', 'name': 'get_workflow', 'input': <String, Object?>{}},
              ],
            }
          : {
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'Done.'},
              ],
            };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200);
    });
    final engine = ApiAssistant(
      credentials: _Credentials([
        const Credential(name: 'claude', type: 'anthropic', values: {'apiKey': 'k'}),
      ]),
      credentialName: 'claude',
      model: 'claude-opus-5-5',
      client: client,
    );
    final events = await engine.send('add a buzz', toolsFor(c)).toList();
    expect(events.whereType<AssistantText>().map((e) => e.text), ['Adding a buzz.', 'Done.']);
    expect(events.whereType<AssistantAction>().first.summary, 'Added “Buzz”');
    expect(requests.first['fallbacks'], 'default');
    final second = asMapList(requests[1]['messages']);
    // The assistant turn goes back whole, thinking included; both results in one user message.
    expect(asMapList(second[1]['content']).first['type'], 'thinking');
    final results = asMapList(second[2]['content']);
    expect(results.map((r) => r['tool_use_id']), ['t1', 't2']);
    expect(c.workflow.nodes.length, 2);
  });

  test('OpenAI-compatible loop runs tool calls', () async {
    final c = await editor();
    var n = 0;
    final client = MockClient((r) async {
      expect(r.url.toString(), 'http://box:11434/v1/chat/completions');
      final reply = n++ == 0
          ? {
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'c1',
                        'type': 'function',
                        'function': {
                          'name': 'set_workflow',
                          'arguments': jsonEncode({'name': 'Buzzer'}),
                        },
                      },
                    ],
                  },
                },
              ],
            }
          : {
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'Renamed it.'},
                },
              ],
            };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200);
    });
    final engine = ApiAssistant(
      credentials: _Credentials([
        const Credential(name: 'box', type: 'openaiCompatible', values: {'baseUrl': 'http://box:11434/v1/'}),
      ]),
      credentialName: 'box',
      model: 'qwen2.5',
      client: client,
    );
    final events = await engine.send('rename to Buzzer', toolsFor(c)).toList();
    expect(c.workflow.name, 'Buzzer');
    expect(events.whereType<AssistantText>().single.text, 'Renamed it.');
  });

  test('a failed request leaves the history valid to retry', () async {
    final c = await editor();
    var fail = true;
    final client = MockClient((r) async {
      if (fail) return http.Response('{"error":{"message":"overloaded"}}', 529);
      final messages = asMapList(asMap(jsonDecode(r.body))['messages']);
      expect(messages.length, 1);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'stop_reason': 'end_turn',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          }),
        ),
        200,
      );
    });
    final engine = ApiAssistant(
      credentials: _Credentials([
        const Credential(name: 'claude', type: 'anthropic', values: {'apiKey': 'k'}),
      ]),
      credentialName: 'claude',
      model: 'claude-opus-5-5',
      client: client,
    );
    final first = await engine.send('hi', toolsFor(c)).toList();
    expect((first.single as AssistantFailure).message, contains('overloaded'));
    fail = false;
    final second = await engine.send('hi', toolsFor(c)).toList();
    expect((second.single as AssistantText).text, 'ok');
  });
}
