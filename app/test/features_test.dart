import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/app_services.dart';
import 'package:flowdroid/core/execution_state.dart';
import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/backup.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/data/execution_record.dart';
import 'package:flowdroid/data/n8n_import.dart';
import 'package:flowdroid/runtime/agent_tools.dart';
import 'package:flowdroid/runtime/credential_resolver.dart';
import 'package:flowdroid/runtime/feeds.dart';
import 'package:flowdroid/runtime/file_effect.dart';
import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flowdroid/runtime/phone/phone_events.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/table_effect.dart';
import 'package:flowdroid/runtime/webhook_server.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

WorkflowNode node(String id, String type, [JsonMap params = const {}]) =>
    WorkflowNode(id: id, name: id, type: type, params: {...params});

class _RealHttp extends HttpOverrides {}

/// Routes the `workflow` effect to [runner] and everything else to fake answers.
class _Effects extends FakeEffects {
  _Effects();

  WorkflowRunner? runner;

  @override
  Map<String, Future<JsonMap> Function(JsonMap effect)> get handlers => {
    ...super.handlers,
    'workflow': (effect) => callWorkflows(effect, runner!.runSubWorkflow),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('runner', () {
    test('Execute Workflow runs the called workflow and returns its last output', () async {
      final repository = await tempRepository();
      final effects = _Effects();
      final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
      effects.runner = runner;
      final child = Workflow(
        id: 'wf_child',
        name: 'Child',
        nodes: [
          node('in', 'trigger.subworkflow'),
          node('set', 'core.set', {
            'fields': [
              {'name': 'doubled', 'value': r'{{ $json.n * 2 }}'},
            ],
          }),
        ],
        connections: [const Connection(from: 'in', to: 'set')],
      );
      await repository.saveWorkflow(child);
      final parent = Workflow(
        id: 'wf_parent',
        name: 'Parent',
        nodes: [
          node('start', 'trigger.manual'),
          node('call', 'core.executeWorkflow', {'workflowId': 'wf_child'}),
        ],
        connections: [const Connection(from: 'start', to: 'call')],
      );
      final record = await runner.run(
        parent,
        triggerNodeId: 'start',
        mode: TriggerMode.manual,
        items: [
          {'n': 21},
        ],
      );
      expect(record.status, ExecutionStatus.success, reason: record.error);
      expect(record.runs.last.outputs.first.single['doubled'], 42);
      expect((await repository.executions('wf_child')).single.mode, TriggerMode.subworkflow);
    });

    test('a workflow that calls itself stops at the depth limit', () async {
      final repository = await tempRepository();
      final effects = _Effects();
      final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
      effects.runner = runner;
      final loop = Workflow(
        id: 'wf_loop',
        name: 'Loop',
        nodes: [
          node('in', 'trigger.subworkflow'),
          node('start', 'trigger.manual'),
          node('call', 'core.executeWorkflow', {'workflowId': 'wf_loop'}),
        ],
        connections: [
          const Connection(from: 'in', to: 'call'),
          const Connection(from: 'start', to: 'call'),
        ],
      );
      await repository.saveWorkflow(loop);
      final record = await runner.run(loop, triggerNodeId: 'start', mode: TriggerMode.manual);
      expect(record.status, ExecutionStatus.error);
      expect(record.error, contains('more than ${WorkflowRunner.maxDepth} levels deep'));
    });

    test('a failed run starts its error workflow with what went wrong', () async {
      final repository = await tempRepository();
      final runner = WorkflowRunner(
        core: core,
        effects: FakeEffects({
          'http': {
            'responses': [
              {'error': 'offline'},
            ],
          },
        }),
        repository: repository,
      );
      await repository.saveWorkflow(
        Workflow(
          id: 'wf_alert',
          name: 'Alert',
          nodes: [node('err', 'trigger.error'), node('ok', 'core.noop')],
          connections: [const Connection(from: 'err', to: 'ok')],
        ),
      );
      final failing = Workflow(
        id: 'wf_fail',
        name: 'Fails',
        errorWorkflowId: 'wf_alert',
        nodes: [
          node('start', 'trigger.manual'),
          node('get', 'http.request', {'url': 'https://x.test'}),
        ],
        connections: [const Connection(from: 'start', to: 'get')],
      );
      final record = await runner.run(failing, triggerNodeId: 'start', mode: TriggerMode.manual);
      expect(record.status, ExecutionStatus.error);
      final alert = (await repository.executions('wf_alert')).single;
      expect(alert.mode, TriggerMode.error);
      final item = alert.runs.first.outputs.first.single;
      expect(asMap(item['workflow'])['name'], 'Fails');
      expect(asMap(item['execution'])['error'], contains('offline'));
    });

    test('manual runs reuse pinned output; triggered runs do not', () async {
      final repository = await tempRepository();
      final effects = FakeEffects({
        'http': {
          'responses': [
            {'status': 200, 'headers': <String, String>{}, 'body': '{"live":true}'},
          ],
        },
      });
      final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
      final fetch = node('get', 'http.request', {'url': 'https://x.test'})
        ..pinned = [
          {'pinned': true},
        ];
      final wf = Workflow(
        id: 'wf_pin',
        name: 'Pin',
        nodes: [node('start', 'trigger.manual'), fetch],
        connections: [const Connection(from: 'start', to: 'get')],
      );
      final manual = await runner.run(wf, triggerNodeId: 'start', mode: TriggerMode.manual);
      expect(manual.runs.last.outputs.first.single, {'pinned': true});
      expect(effects.performed, isEmpty);
      final live = await runner.run(wf, triggerNodeId: 'start', mode: TriggerMode.schedule);
      expect(live.runs.last.outputs.first.single, {'live': true});
    });
  });

  group('n8n import', () {
    test('maps nodes, expressions and connections by name', () {
      final imported = importN8n({
        'name': 'From n8n',
        'nodes': [
          {
            'name': 'When clicking',
            'type': 'n8n-nodes-base.manualTrigger',
            'typeVersion': 1,
            'parameters': <String, Object?>{},
          },
          {
            'name': 'Get user',
            'type': 'n8n-nodes-base.httpRequest',
            'typeVersion': 4,
            'parameters': {'method': 'POST', 'url': '=https://api.test/{{ \$json.id }}'},
          },
          {
            'name': 'Adult?',
            'type': 'n8n-nodes-base.if',
            'typeVersion': 2,
            'parameters': {
              'conditions': {
                'combinator': 'or',
                'conditions': [
                  {
                    'leftValue': "={{ \$('Get user').item.json.age }}",
                    'rightValue': 18,
                    'operator': {'type': 'number', 'operation': 'gte'},
                  },
                ],
              },
            },
          },
          {
            'name': 'Mystery',
            'type': 'n8n-nodes-base.someService',
            'typeVersion': 1,
            'parameters': <String, Object?>{},
          },
        ],
        'connections': {
          'When clicking': {
            'main': [
              [
                {'node': 'Get user', 'type': 'main', 'index': 0},
              ],
            ],
          },
          'Get user': {
            'main': [
              [
                {'node': 'Adult?', 'type': 'main', 'index': 0},
              ],
            ],
          },
          'Adult?': {
            'main': [
              <Object?>[],
              [
                {'node': 'Mystery', 'type': 'main', 'index': 0},
              ],
            ],
          },
        },
      });
      final wf = imported.workflow;
      expect(wf.name, 'From n8n');
      expect(wf.nodes.map((n) => n.type), ['trigger.manual', 'http.request', 'core.if', 'core.noop']);
      expect(wf.nodes[1].params['url'], r'https://api.test/{{ $json.id }}');
      expect(wf.nodes[2].params['combine'], 'or');
      expect(wf.nodes[2].params['conditions'], [
        {'left': r'{{ $node["Get user"].json.age }}', 'op': 'gte', 'right': 18},
      ]);
      expect(wf.nodes[3].name, 'Mystery (not supported)');
      expect(imported.unsupported, ['n8n-nodes-base.someService']);
      final ifToMystery = wf.connections.singleWhere((c) => c.to == wf.nodes[3].id);
      expect(ifToMystery.output, 1);
      expect(core.validateWorkflow(wf.toJson()), isEmpty);
    });

    test('recognises n8n exports', () {
      expect(isN8nWorkflow({'nodes': [], 'connections': <String, Object?>{}}), isTrue);
      expect(isN8nWorkflow({'nodes': [], 'connections': <Object?>[]}), isFalse);
    });
  });

  test('backups restore with the right passphrase only', () async {
    final source = await tempRepository();
    final store = CredentialStore();
    await source.saveWorkflow(Workflow(id: 'wf_a', name: 'A', nodes: [node('s', 'trigger.manual')]));
    await store.save(const Credential(name: 'Key', type: 'bearerAuth', values: {'token': 'secret-token'}));
    final file = await Backup(source, store).export('correct horse');
    expect(utf8.decode(file), isNot(contains('secret-token')));

    FlutterSecureStorage.setMockInitialValues({});
    final target = await tempRepository();
    final fresh = CredentialStore();
    expect(
      () => Backup(target, fresh).restore(file, 'wrong'),
      throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('wrong passphrase'))),
    );
    final (workflows, credentials) = await Backup(target, fresh).restore(file, 'correct horse');
    expect((workflows, credentials), (1, 1));
    expect((await fresh.byName('Key'))?.values['token'], 'secret-token');
    expect((await target.workflow('wf_a'))?.name, 'A');
  });

  test('HTTP Request credentials add the right authentication header', () async {
    final store = CredentialStore();
    await store.save(const Credential(name: 'B', type: 'basicAuth', values: {'user': 'ann', 'password': 'pw'}));
    await store.save(const Credential(name: 'H', type: 'headerAuth', values: {'name': 'X-Key', 'value': 'k123456'}));
    final resolver = CredentialResolver(store);
    JsonMap request(String credential) => {
      'url': 'https://x.test',
      'headers': <String, Object?>{},
      'credential': credential,
      'auth': true,
    };
    final (basic, _) = await resolver.resolve(request('B'));
    expect(basic['headers'], {'Authorization': 'Basic ${base64.encode(utf8.encode('ann:pw'))}'});
    expect(basic.containsKey('auth'), isFalse);
    final (header, _) = await resolver.resolve(request('H'));
    expect(header['headers'], {'X-Key': 'k123456'});
  });

  test('phone event filters', () {
    final sms = node('t', 'trigger.sms', {'from': '+1 (555) 010', 'contains': 'CODE'});
    expect(PhoneEvents.matches(sms, {'from': '+15550100', 'text': 'your code is 1'}), isTrue);
    expect(PhoneEvents.matches(sms, {'from': '+15559999', 'text': 'code'}), isFalse);
    final notification = node('n', 'trigger.notification', {'app': 'whatsapp'});
    expect(PhoneEvents.matches(notification, {'app': 'WhatsApp', 'package': 'com.whatsapp', 'title': 'Ann'}), isTrue);
    expect(PhoneEvents.matches(notification, {'app': 'Gmail', 'package': 'com.google.android.gm'}), isFalse);
    final phone = node('p', 'trigger.phone', {'event': 'wifiConnected'});
    expect(PhoneEvents.matches(phone, {'event': 'wifiConnected'}), isTrue);
    expect(PhoneEvents.matches(phone, {'event': 'powerConnected'}), isFalse);
  });

  test('phone events run the matching active workflows', () async {
    final dir = await Directory.systemTemp.createTemp('flowdroid_events');
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final wf = Workflow(
      id: 'wf_sms',
      name: 'SMS',
      active: true,
      nodes: [
        node('t', 'trigger.sms', {'contains': 'hi'}),
      ],
    );
    await repository.saveWorkflow(wf);
    final events = PhoneEvents(dataDir: dir, repository: repository, runner: runner);
    await Directory('${dir.path}/events').create();
    await File('${dir.path}/events/1-1.json').writeAsString(
      jsonEncode({'type': 'sms', 'from': '+1', 'text': 'hi there', 'at': DateTime.now().millisecondsSinceEpoch}),
    );
    await events.poll();
    final run = (await repository.executions('wf_sms')).single;
    expect(run.mode, TriggerMode.sms);
    expect(run.runs.single.outputs.first.single['text'], 'hi there');
    expect(await File('${dir.path}/events/1-1.json').exists(), isFalse);
  });

  test('reads RSS and Atom feeds', () {
    final rss = FeedReader.parse(
      '<rss><channel><item><title>A</title><link>https://a</link><guid>1</guid></item></channel></rss>',
    );
    expect(rss.single, containsPair('title', 'A'));
    expect(rss.single['id'], '1');
    final atom = FeedReader.parse(
      '<feed><entry><title>B</title><link rel="alternate" href="https://b"/><id>2</id>'
      '<updated>2026-01-01</updated></entry></feed>',
    );
    expect(atom.single['link'], 'https://b');
    expect(atom.single['published'], '2026-01-01');
    expect(() => FeedReader.parse('not xml <'), throwsA(isA<FeedException>()));
  });

  test('the Files node stays inside its folder', () async {
    final root = await Directory.systemTemp.createTemp('flowdroid_files');
    final files = FileEffect(root);
    final write = await files({
      'requests': [
        {'operation': 'write', 'path': 'notes/a.txt', 'content': 'hello'},
      ],
    });
    expect(asList(write['results']).single, {'path': 'notes/a.txt', 'size': 5});
    final read = await files({
      'requests': [
        {'operation': 'read', 'path': 'notes/a.txt'},
      ],
    });
    expect(asMap(asList(read['results']).single)['content'], 'hello');
    final escape = await files({
      'requests': [
        {'operation': 'read', 'path': '../secret'},
      ],
    });
    expect(escape['error'], contains('must stay inside'));
  });

  test('webhooks with a key answer 401 without it and never store it', () async {
    final repository = await tempRepository();
    final store = CredentialStore();
    await store.save(const Credential(name: 'Hook', type: 'webhookAuth', values: {'value': 's3cret-key'}));
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final server = WebhookServer(repository: repository, runner: runner, credentials: store, port: 56793);
    await repository.saveWorkflow(
      Workflow(
        id: 'wf_hook',
        name: 'Hook',
        active: true,
        nodes: [
          node('h', 'trigger.webhook', {'path': 'secure', 'method': 'POST', 'credential': 'Hook'}),
        ],
      ),
    );
    await server.start();
    addTearDown(server.stop);
    // The test binding fakes HttpClient (every call answers 400); talk to the real server instead.
    Future<int> send(String? key) async {
      final request = await HttpClient().post('127.0.0.1', 56793, '/webhook/secure');
      if (key != null) request.headers.set('X-FlowDroid-Key', key);
      request.headers.contentType = ContentType.json;
      request.write('{}');
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    Future<int> call([String? key]) => HttpOverrides.runWithHttpOverrides(() => send(key), _RealHttp());

    expect(await call(), 401);
    expect(await call('wrong'), 401);
    expect(await call('s3cret-key'), 200);
    final history = jsonEncode((await repository.executions('wf_hook')).single.toJson());
    expect(history, isNot(contains('s3cret-key')));
  });

  test('agent tools use phone tables and other workflows', () async {
    final dir = await Directory.systemTemp.createTemp('flowdroid_tools');
    final tools = AgentTools(
      linux: LinuxRuntime(dir, shell: '/bin/sh', libraryDir: '/nonexistent'),
      tables: TableEffect(dir),
      callWorkflow: (id, items) async => [
        {'called': id, 'with': items.single},
      ],
    );
    final result = await tools({
      'calls': [
        {
          'id': '1',
          'kind': 'table',
          'name': 'db',
          'config': 'notes',
          'input': {
            'operation': 'insert',
            'row': {'a': 1},
          },
        },
        {
          'id': '2',
          'kind': 'workflow',
          'name': 'wf',
          'config': 'wf_x',
          'input': {
            'input': {'q': 'hi'},
          },
        },
        {'id': '3', 'kind': '', 'name': 'ghost', 'config': '', 'input': <String, Object?>{}},
        {
          'id': '4',
          'kind': 'http',
          'name': 'web',
          'config': 'https://allowed/',
          'input': {'url': 'https://other/'},
        },
      ],
    });
    final results = asMapList(result['results']);
    expect(results[0]['isError'], isFalse);
    expect(jsonDecode(asString(results[0]['content'])), [containsPair('a', 1)]);
    expect(jsonDecode(asString(results[1]['content'])), [
      {
        'called': 'wf_x',
        'with': {'q': 'hi'},
      },
    ]);
    expect(results[2], {'content': 'there is no tool named “ghost”', 'isError': true});
    expect(results[3]['content'], 'the URL must start with https://allowed/');
  });
}
