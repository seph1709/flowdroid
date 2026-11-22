import 'package:flowdroid/core/execution_state.dart';
import 'package:flowdroid/data/execution_record.dart';
import 'package:flowdroid/data/templates.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('catalog lists every node type with its parameters', () {
    final catalog = core.nodeCatalog();
    expect(catalog.map((t) => t.type), containsAll(['trigger.manual', 'http.request', 'android.notify', 'core.merge']));
    expect(catalog.firstWhere((t) => t.type == 'core.if').outputs, ['true', 'false']);
  });

  test('evaluates expressions and reports errors with their kind', () {
    expect(
      core.evaluateTemplate('{{ \$json.n * 2 }}', {
        r'$json': {'n': 21},
      }),
      42,
    );
    expect(
      () => core.evaluateTemplate('{{ \$nope }}', {}),
      throwsA(isA<Object>().having((e) => e.toString(), 'message', r'ExpressionError: unknown variable $nope')),
    );
  });

  test('runs the low battery template through its effects and saves the execution', () async {
    final repository = await tempRepository();
    final effects = FakeEffects({
      'battery': {'level': 12, 'charging': false},
    });
    final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
    final wf = templates.firstWhere((t) => t.title == 'Low battery alert').build();

    final record = await runner.run(wf, triggerNodeId: wf.nodes.first.id, mode: TriggerMode.manual);

    expect(record.status, ExecutionStatus.success);
    expect(effects.performed.map((e) => e['type']), ['battery', 'notify']);
    expect(effects.performed.last['notifications'], [
      {'title': 'Battery low', 'body': 'Only 12% left. Time to charge.'},
    ]);
    expect((await repository.executions(wf.id)).single.id, record.id);
  });

  test('a failing HTTP call fails the execution with the node name', () async {
    final repository = await tempRepository();
    final effects = FakeEffects({
      'http': {
        'responses': [
          {'status': 503, 'headers': <String, Object?>{}, 'body': 'down'},
        ],
      },
    });
    final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
    final wf = templates.firstWhere((t) => t.title == 'Morning quote').build();

    final record = await runner.run(wf, triggerNodeId: wf.nodes.first.id, mode: TriggerMode.schedule);

    expect(record.status, ExecutionStatus.error);
    expect(record.error, 'Get quote: NodeError: request failed with status 503');
  });

  test('every template passes the core validation', () {
    for (final t in templates) {
      expect(core.validateWorkflow(t.build().toJson()), isEmpty, reason: t.title);
    }
  });
}
