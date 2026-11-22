import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/core/execution_state.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/data/execution_record.dart';
import 'package:flowdroid/runtime/credential_resolver.dart';
import 'package:flowdroid/runtime/http_effect.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/table_effect.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// A manual trigger followed by one node of [type].
Workflow single(String type, Map<String, Object?> params) {
  final trigger = WorkflowNode(id: 'n_t', name: 'Start', type: 'trigger.manual');
  final node = WorkflowNode(id: 'n_1', name: 'Step', type: type, params: params);
  return Workflow(
    id: 'wf_test',
    name: 'Test',
    nodes: [trigger, node],
    connections: [const Connection(from: 'n_t', to: 'n_1')],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('credentials fill placeholders only at send time and never reach history', () async {
    final store = CredentialStore();
    await store.save(const Credential(name: 'Bot', type: 'telegram', values: {'botToken': '123456:SECRET'}));
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return http.Response(
        jsonEncode({
          'ok': true,
          'result': {'message_id': 7},
        }),
        200,
      );
    });
    final effects = FakeEffects();
    final dispatcher = HttpEffect(client: client, credentials: CredentialResolver(store));
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, repository: repository, effects: _Only('http', dispatcher.call, effects));
    final wf = single('telegram.send', {'credential': 'Bot', 'chatId': '42', 'text': 'hi', 'parseMode': 'none'});

    final record = await runner.run(wf, triggerNodeId: 'n_t', mode: TriggerMode.manual);

    expect(record.status, ExecutionStatus.success, reason: record.error);
    expect(sent.single.url.toString(), 'https://api.telegram.org/bot123456:SECRET/sendMessage');
    expect(jsonDecode(sent.single.body), {'chat_id': '42', 'text': 'hi'});
    final history = jsonEncode((await repository.executions(wf.id)).single.toJson());
    expect(history, isNot(contains('SECRET')));
    expect(history, contains('message_id'));
  });

  test('a missing credential fails the node with a clear message', () async {
    final resolver = CredentialResolver(CredentialStore());
    expect(
      () => resolver.resolve({'url': '{cred:url}', 'credential': 'Nope'}),
      throwsA(isA<CredentialException>().having((e) => e.message, 'message', contains('"Nope" not found'))),
    );
  });

  test('placeholder defaults apply when an optional field is empty', () async {
    final store = CredentialStore();
    await store.save(const Credential(name: 'AI', type: 'openai', values: {'apiKey': 'sk-abcdef', 'baseUrl': ''}));
    final (request, secrets) = await CredentialResolver(store).resolve({
      'url': '{cred:baseUrl|https://api.openai.com/v1}/chat/completions',
      'headers': {'Authorization': 'Bearer {cred:apiKey}'},
      'credential': 'AI',
    });
    expect(request['url'], 'https://api.openai.com/v1/chat/completions');
    expect(request['headers'], {'Authorization': 'Bearer sk-abcdef'});
    expect(request.containsKey('credential'), isFalse);
    expect(scrub('failed for sk-abcdef', secrets), 'failed for •••');
  });

  test('phone table inserts, finds, updates and deletes rows', () async {
    final tables = TableEffect(await Directory.systemTemp.createTemp('flowdroid_tables'));
    JsonRequest req({Map<String, Object?> where = const {}, Map<String, Object?>? row}) => {
      'where': where,
      'row': row,
      'limit': 100,
    };

    await tables({
      'table': 'notes',
      'operation': 'insert',
      'requests': [
        req(row: {'id': 1, 'text': 'a'}),
        req(row: {'id': 2, 'text': 'b'}),
      ],
    });
    expect(
      (await tables({
        'table': 'notes',
        'operation': 'find',
        'requests': [
          req(where: {'id': '2'}),
        ],
      }))['rows'],
      [allOf(containsPair('id', 2), containsPair('text', 'b'))],
    );
    await tables({
      'table': 'notes',
      'operation': 'update',
      'requests': [
        req(where: {'id': '1'}, row: {'text': 'A'}),
      ],
    });
    await tables({
      'table': 'notes',
      'operation': 'delete',
      'requests': [
        req(where: {'id': '2'}),
      ],
    });
    final all =
        (await tables({
              'table': 'notes',
              'operation': 'find',
              'requests': [req()],
            }))['rows']!
            as List;
    expect(all, [allOf(containsPair('id', 1), containsPair('text', 'A'))]);
  });

  test('Execute Command outputs what the command printed and fails on a non-zero exit', () async {
    final repository = await tempRepository();
    Future<ExecutionRecord> run(Map<String, Object?> result) =>
        WorkflowRunner(
          core: core,
          repository: repository,
          effects: FakeEffects({
            'command': {
              'results': [result],
            },
          }),
        ).run(
          single('system.command', {'target': 'phone', 'command': 'uname'}),
          triggerNodeId: 'n_t',
          mode: TriggerMode.manual,
        );

    final ok = await run({'exitCode': 0, 'stdout': 'Linux\n', 'stderr': ''});
    expect(ok.status, ExecutionStatus.success);
    expect(ok.runs.last.outputs.first.first, {'exitCode': 0, 'stdout': 'Linux\n', 'stderr': ''});

    final failed = await run({'exitCode': 2, 'stdout': '', 'stderr': ' no such file \n'});
    expect(failed.status, ExecutionStatus.error);
    expect(failed.error, contains('command exited with code 2: no such file'));
  });
}

typedef JsonRequest = Map<String, Object?>;

/// Routes one effect type to [handler] and the rest to [fallback].
class _Only extends FakeEffects {
  _Only(this.type, this.handler, this.fallback);

  final String type;
  final Future<Map<String, Object?>> Function(Map<String, Object?>) handler;
  final FakeEffects fallback;

  @override
  Map<String, Future<Map<String, Object?>> Function(Map<String, Object?> effect)> get handlers => {
    ...fallback.handlers,
    type: handler,
  };
}
