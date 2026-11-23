import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/credential_resolver.dart';
import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flowdroid/runtime/mcp_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('MCP over HTTP', () {
    late List<http.Request> sent;
    late int sessions;

    /// A small Streamable HTTP server: JSON for initialize, SSE for tool calls.
    MockClient server({bool forgetFirstSession = false}) {
      sessions = 0;
      var forgot = !forgetFirstSession;
      return MockClient((request) async {
        sent.add(request);
        if (request.method == 'DELETE') return http.Response('', 405);
        final message = asMap(jsonDecode(request.body));
        final id = message['id'];
        final method = asString(message['method']);
        if (method == 'initialize') {
          sessions++;
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'protocolVersion': '2025-03-26',
                'capabilities': {'tools': <String, Object?>{}},
                'serverInfo': {'name': 'test', 'version': '1'},
              },
            }),
            200,
            headers: {'content-type': 'application/json', 'mcp-session-id': 'S$sessions'},
          );
        }
        if (id == null) return http.Response('', 202);
        if (!forgot) {
          forgot = true;
          return http.Response('session gone', 404);
        }
        final params = asMap(message['params']);
        if (params['name'] == 'broken') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32602, 'message': 'Unknown tool: broken'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final note = jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': <String, Object?>{}});
        final reply = jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': 'echo ${asMap(params['arguments'])['q']}'},
            ],
          },
        });
        return http.Response(
          'event: message\ndata: $note\n\nevent: message\ndata: $reply\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
    }

    Future<McpClient> client(MockClient http) async {
      final store = CredentialStore();
      await store.save(const Credential(name: 'Token', type: 'bearerAuth', values: {'token': 'sekret-token'}));
      final dir = await Directory.systemTemp.createTemp('mcp_test');
      addTearDown(() => dir.delete(recursive: true));
      return McpClient(linux: LinuxRuntime(dir), credentials: CredentialResolver(store), client: http);
    }

    JsonMap effect(List<JsonMap> calls) => {
      'type': 'mcp',
      'server': {'transport': 'http', 'url': 'https://mcp.test/mcp', 'credential': 'Token'},
      'calls': calls,
      'timeoutMs': 5000,
    };

    JsonMap callTool(String name, String q) => {
      'method': 'tools/call',
      'params': {
        'name': name,
        'arguments': {'q': q},
      },
    };

    setUp(() => sent = []);

    test('initializes once, signs in, and reads answers sent as events', () async {
      final mcp = await client(server());
      addTearDown(mcp.closeAll);

      final first = await mcp.call(effect([callTool('echo', 'a'), callTool('broken', 'b')]));
      expect(first, {
        'results': [
          {
            'result': {
              'content': [
                {'type': 'text', 'text': 'echo a'},
              ],
            },
          },
          {'error': 'Unknown tool: broken'},
        ],
      });
      final second = await mcp.call(effect([callTool('echo', 'c')]));
      expect(asMapList(second['results']).single['result'], isNotNull);

      expect(sessions, 1);
      expect(sent.map((r) => asString(asMap(jsonDecode(r.body))['method'])), [
        'initialize',
        'notifications/initialized',
        'tools/call',
        'tools/call',
        'tools/call',
      ]);
      expect(sent.first.headers['Authorization'], 'Bearer sekret-token');
      expect(sent.first.headers.containsKey('Mcp-Session-Id'), isFalse);
      final call = sent[2];
      expect(call.headers['Mcp-Session-Id'], 'S1');
      expect(call.headers['MCP-Protocol-Version'], '2025-03-26');
      expect(call.headers['Accept'], 'application/json, text/event-stream');
    });

    test('starts a new session when the server forgets the old one', () async {
      final mcp = await client(server(forgetFirstSession: true));
      addTearDown(mcp.closeAll);
      final result = await mcp.call(effect([callTool('echo', 'x')]));
      expect(asMapList(result['results']).single['result'], isNotNull);
      expect(sessions, 2);
    });

    test('reports servers that fail, without leaking the credential', () async {
      final failing = MockClient((request) async => http.Response('bad token sekret-token', 401));
      final mcp = await client(failing);
      expect(await mcp.call(effect([callTool('echo', 'x')])), {'error': 'MCP server error 401: bad token •••'});
    });
  });

  group('MCP over stdio', () {
    test('talks JSON-RPC line by line and answers the server’s own requests', () async {
      final process = _FakeServer();
      final transport = StdioTransport(process);
      final result = await transport.request('tools/list', {}, const Duration(seconds: 5));
      expect(result, {
        'tools': [
          {'name': 'echo'},
        ],
      });
      // The server pinged FlowDroid and asked for something it doesn't offer.
      expect(process.received.map((m) => m['id']), containsAll(['p1', 'r1']));
      final ping = process.received.firstWhere((m) => m['id'] == 'p1');
      expect(ping['result'], <String, Object?>{});
      final roots = process.received.firstWhere((m) => m['id'] == 'r1');
      expect(asMap(roots['error'])['code'], -32601);

      await expectLater(
        transport.request('crash', {}, const Duration(seconds: 5)),
        throwsA(isA<McpException>().having((e) => e.message, 'message', 'the MCP server stopped (exit 1): boom')),
      );
    });
  });
}

/// A stdio MCP server in a fake process: answers `tools/list`, exits on `crash`.
class _FakeServer implements Process {
  _FakeServer() {
    _in.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final message = asMap(jsonDecode(line));
      received.add(message);
      final method = message['method'];
      if (method == 'tools/list') {
        _say('not json, a log line');
        _say(jsonEncode({'jsonrpc': '2.0', 'id': 'p1', 'method': 'ping'}));
        _say(jsonEncode({'jsonrpc': '2.0', 'id': 'r1', 'method': 'roots/list'}));
        _say(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': {
              'tools': [
                {'name': 'echo'},
              ],
            },
          }),
        );
      } else if (method == 'crash') {
        _err.add(utf8.encode('starting\nboom\n'));
        Future<void>.delayed(const Duration(milliseconds: 20), () => _exit.complete(1));
      }
    });
  }

  final received = <JsonMap>[];
  final _in = StreamController<List<int>>();
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();

  void _say(String line) => _out.add(utf8.encode('$line\n'));

  @override
  late final IOSink stdin = IOSink(_in.sink);

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}
