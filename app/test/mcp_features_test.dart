import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/cli_chat.dart';
import 'package:flowdroid/runtime/credential_resolver.dart';
import 'package:flowdroid/runtime/file_store.dart';
import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flowdroid/runtime/mcp_client.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/webhook_server.dart';
import 'package:flowdroid/ui/editor/editor_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('mcp_features');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  group('saved MCP servers and the AI Agent', () {
    /// A web MCP server that pages its tool list and echoes tool calls.
    MockClient server(List<http.Request> sent) => MockClient((request) async {
      sent.add(request);
      final message = asMap(jsonDecode(request.body));
      final id = message['id'];
      if (id == null) return http.Response('', 202);
      final params = asMap(message['params']);
      final JsonMap result = switch (message['method']) {
        'initialize' => {'protocolVersion': '2025-06-18', 'capabilities': <String, Object?>{}},
        'tools/list' when params['cursor'] == null => {
          'tools': [
            {
              'name': 'search',
              'inputSchema': <String, Object?>{'type': 'object'},
            },
          ],
          'nextCursor': 'p2',
        },
        'tools/list' => {
          'tools': [
            {'name': 'fetch'},
          ],
        },
        _ when params['name'] == 'fails' => {
          'content': [
            {'type': 'text', 'text': 'not allowed'},
          ],
          'isError': true,
        },
        _ => {
          'content': [
            {'type': 'text', 'text': 'got ${jsonEncode(params['arguments'])}'},
          ],
        },
      };
      return http.Response(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    test('lists every page of a saved server’s tools and calls them, signed in', () async {
      final store = CredentialStore();
      await store.save(
        const Credential(
          name: 'Docs',
          type: 'mcpServer',
          values: {'url': 'https://docs.test/mcp', 'headerName': 'X-Key', 'headerValue': 'docs-secret'},
        ),
      );
      final sent = <http.Request>[];
      final mcp = McpClient(
        linux: LinuxRuntime(await tempDir()),
        credentials: CredentialResolver(store),
        client: server(sent),
      );
      addTearDown(mcp.closeAll);

      final listed = await mcp.listTools({
        'servers': [
          {'name': 'docs', 'config': 'Docs'},
          {'name': 'none', 'config': ''},
        ],
        'timeoutMs': 5000,
      });
      expect(asMapList(listed['results']).first['tools'], [
        {
          'name': 'search',
          'inputSchema': {'type': 'object'},
        },
        {'name': 'fetch'},
      ]);
      expect(asMapList(listed['results']).last, {'error': 'this tool has no MCP server'});
      expect(sent.first.url.toString(), 'https://docs.test/mcp');
      expect(sent.first.headers['X-Key'], 'docs-secret');

      expect(await mcp.callTool('Docs', 'search', {'q': 'cats'}, const Duration(seconds: 5)), 'got {"q":"cats"}');
      await expectLater(
        mcp.callTool('Docs', 'fails', {}, const Duration(seconds: 5)),
        throwsA(isA<McpException>().having((e) => e.message, 'message', 'not allowed')),
      );
      // One session for all of it.
      expect(sent.where((r) => r.body.contains('"initialize"')).length, 1);
    });

    test('an agent tool’s server is a saved server, a URL or a command', () async {
      final store = CredentialStore();
      await store.save(const Credential(name: 'Mine', type: 'mcpServer', values: {'command': 'srv'}));
      await store.save(const Credential(name: 'Bot', type: 'telegram', values: {'botToken': 'x'}));
      final mcp = McpClient(linux: LinuxRuntime(await tempDir()), credentials: CredentialResolver(store));
      expect(await mcp.serverFor('Mine'), {'transport': 'saved', 'credential': 'Mine'});
      expect(await mcp.serverFor(' https://x/mcp '), {'transport': 'http', 'url': 'https://x/mcp'});
      expect(await mcp.serverFor('Bot'), {'transport': 'stdio', 'command': 'Bot'});
      expect(McpClient.parseEnv('A=1; B_2 = two\nbad;=x;C=a=b'), {'A': '1', 'B_2': 'two', 'C': 'a=b'});
    });
  });

  group('Claude Code MCP servers with saved credentials', () {
    test('fill in the server, its sign-in header and placeholders, without keys in the workflow', () async {
      final store = CredentialStore();
      await store.save(
        const Credential(
          name: 'GitHub MCP',
          type: 'mcpServer',
          values: {'command': 'npx -y gh-server', 'env': 'GITHUB_TOKEN=ghp_secret123'},
        ),
      );
      await store.save(
        const Credential(
          name: 'Docs',
          type: 'mcpServer',
          values: {'url': 'https://d/mcp', 'headerValue': 'Bearer tok123'},
        ),
      );
      await store.save(const Credential(name: 'Token', type: 'bearerAuth', values: {'token': 'bearer-secret'}));
      await store.save(const Credential(name: 'Notion', type: 'notion', values: {'token': 'ntn_secret9'}));
      final dir = await tempDir();
      final chat = CliChat(linux: LinuxRuntime(dir), files: FileStore(dir), credentials: CredentialResolver(store));

      final (servers, secrets) = await chat.expandServers({
        'gh': {'credential': 'GitHub MCP'},
        'docs': {
          'credential': 'Docs',
          'headers': {'X-Extra': '1'},
        },
        'api': {'type': 'http', 'url': 'https://api/mcp', 'credential': 'Token'},
        'notion': {
          'command': 'npx',
          'args': ['notion-mcp'],
          'env': {'NOTION_TOKEN': '{cred:token}'},
          'credential': 'Notion',
        },
        'plain': {'type': 'http', 'url': 'https://p/mcp'},
      });
      expect(servers, {
        'gh': {
          'command': 'bash',
          'args': ['-lc', 'npx -y gh-server'],
          'env': {'GITHUB_TOKEN': 'ghp_secret123'},
        },
        'docs': {
          'type': 'http',
          'url': 'https://d/mcp',
          'headers': {'Authorization': 'Bearer tok123', 'X-Extra': '1'},
        },
        'api': {
          'type': 'http',
          'url': 'https://api/mcp',
          'headers': {'Authorization': 'Bearer bearer-secret'},
        },
        'notion': {
          'command': 'npx',
          'args': ['notion-mcp'],
          'env': {'NOTION_TOKEN': 'ntn_secret9'},
        },
        'plain': {'type': 'http', 'url': 'https://p/mcp'},
      });
      expect(secrets, containsAll(['ghp_secret123', 'bearer-secret', 'ntn_secret9']));

      await expectLater(
        chat.expandServers({
          'x': {'credential': 'Missing'},
        }),
        throwsA(isA<CredentialException>()),
      );
    });
  });

  group('FlowDroid’s MCP server', () {
    late int port;
    var nextPort = 56790;

    Future<(int, Object?)> post(Object body, {Map<String, String> headers = const {}}) async {
      final request = await HttpClient().post('127.0.0.1', port, '/mcp');
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
    }

    JsonMap rpc(int id, String method, [JsonMap params = const {}]) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    Workflow toolWorkflow(String id, String name, {String credential = ''}) => Workflow(
      id: id,
      name: 'Notes $id',
      nodes: [
        WorkflowNode(
          id: 't',
          name: 'Tool',
          type: 'trigger.mcp',
          params: {
            'name': name,
            'description': 'Saves a note',
            'inputSchema': '{"type": "object", "properties": {"text": {"type": "string"}}}',
            'credential': credential,
          },
        ),
        WorkflowNode(
          id: 's',
          name: 'Set',
          type: 'core.set',
          params: {
            'fields': [
              {'name': 'saved', 'value': r'{{ $json.text + "!" }}'},
            ],
          },
        ),
      ],
      connections: [const Connection(from: 't', to: 's')],
    )..active = true;

    setUp(() async {
      // The test binding answers every HttpClient request with 400; these talk to a real server.
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      port = nextPort++;
      final store = CredentialStore();
      await store.save(const Credential(name: 'Key', type: 'webhookAuth', values: {'value': 'k-123456'}));
      final repository = await tempRepository();
      await repository.saveWorkflow(toolWorkflow('a', 'add_note'));
      await repository.saveWorkflow(toolWorkflow('b', 'secret_note', credential: 'Key'));
      await repository.saveWorkflow(toolWorkflow('c', 'add_note'));
      await repository.saveWorkflow(toolWorkflow('d', 'off')..active = false);
      final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
      final server = WebhookServer(repository: repository, runner: runner, credentials: store, port: port);
      await server.start();
      addTearDown(server.stop);
    });

    test('lists active workflows as tools, and a tool call runs its workflow', () async {
      final (status, init) = await post(rpc(1, 'initialize', {'protocolVersion': '2025-03-26'}));
      expect(status, 200);
      expect(asMap(asMap(init)['result'])['protocolVersion'], '2025-03-26');
      expect((await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'})).$1, 202);

      final (_, listed) = await post(rpc(2, 'tools/list'));
      final tools = asMapList(asMap(asMap(listed)['result'])['tools']);
      expect(tools.map((t) => t['name']), ['add_note']);
      expect(tools.single['inputSchema'], {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      });

      final (_, called) = await post(
        rpc(3, 'tools/call', {
          'name': 'add_note',
          'arguments': {'text': 'milk'},
        }),
      );
      final content = asMapList(asMap(asMap(called)['result'])['content']);
      expect(asMap(jsonDecode(asString(content.single['text'])))['saved'], 'milk!');

      final (_, unknown) = await post(rpc(4, 'tools/call', {'name': 'nope'}));
      expect(asMap(asMap(unknown)['error'])['code'], -32602);
      final (_, missing) = await post(rpc(5, 'resources/list'));
      expect(asMap(asMap(missing)['error'])['code'], -32601);
    });

    test('a tool that requires a key is offered only to callers that send it', () async {
      final (_, listed) = await post(rpc(1, 'tools/list'), headers: {'X-FlowDroid-Key': 'k-123456'});
      expect(asMapList(asMap(asMap(listed)['result'])['tools']).map((t) => t['name']), ['add_note', 'secret_note']);
      final (_, wrong) = await post(rpc(2, 'tools/call', {'name': 'secret_note'}), headers: {'X-FlowDroid-Key': 'bad'});
      expect(asMap(asMap(wrong)['error'])['message'], 'Unknown tool: secret_note');
    });

    test('refuses web pages and other methods', () async {
      expect((await post(rpc(1, 'ping'), headers: {'Origin': 'https://evil.example'})).$1, 403);
      expect((await post(rpc(1, 'ping'), headers: {'Origin': 'http://localhost:3000'})).$1, 200);
      final get = await (await HttpClient().get('127.0.0.1', port, '/mcp')).close();
      expect(get.statusCode, 405);
    });
  });

  test('a manual run of an MCP Tool Trigger gets arguments shaped like its schema', () {
    expect(
      EditorController.sampleArguments(
        '{"type":"object","properties":{"text":{"type":"string"},"n":{"type":"integer"},"ok":{"type":"boolean"}}}',
      ),
      {'text': 'test', 'n': 1, 'ok': true},
    );
    expect(EditorController.sampleArguments('{bad'), <String, Object?>{});
  });
}
