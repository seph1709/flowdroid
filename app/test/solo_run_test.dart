import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/solo_run.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/execution_record.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

WorkflowNode n(String id, String type, [JsonMap params = const {}]) =>
    WorkflowNode(id: id, name: id, type: type, params: {...params});

void main() {
  test(r'runs only the step, on the earlier output, with $node references intact', () async {
    final repository = await tempRepository();
    final effects = FakeEffects();
    final runner = WorkflowRunner(core: core, effects: effects, repository: repository);
    final wf = Workflow(
      id: 'wf',
      name: 'Solo',
      nodes: [
        n('start', 'trigger.manual'),
        n('First', 'core.set', {
          'fields': [
            {'name': 'a', 'value': '{{ 20 + 1 }}'},
          ],
        }),
        n('Buzz', 'android.vibrate', {'ms': 100}),
        n('Second', 'core.set', {
          'fields': [
            {'name': 'b', 'value': '{{ \$json.a * 2 }}'},
          ],
        }),
      ],
      connections: [
        const Connection(from: 'start', to: 'First'),
        const Connection(from: 'First', to: 'Buzz'),
        const Connection(from: 'Buzz', to: 'Second'),
      ],
    );
    final full = await runner.run(wf, triggerNodeId: 'start', mode: TriggerMode.manual, items: [{}]);
    expect(full.succeeded, isTrue);
    expect(effects.performed, hasLength(1), reason: 'the full run vibrated once');

    // Change only the last step, then test it alone.
    wf.node('Second')!.params['fields'] = [
      {'name': 'b', 'value': '{{ \$json.a * 3 }}'},
      {'name': 'from', 'value': '{{ \$node["First"].json.a }}'},
    ];
    final plan = soloRun(
      wf,
      'Second',
      portOutput: (id, port) => full.runOf(id)?.outputs[port],
      allOutput: (id) => full.runOf(id)?.outputs.expand((i) => i).toList(),
    );
    final solo = await runner.run(
      plan.workflow,
      triggerNodeId: plan.startId,
      mode: TriggerMode.manual,
      items: const [{}],
      usePinned: true,
      keep: false,
    );
    expect(solo.runOf('Second')!.outputs.single.single, containsPair('b', 63));
    expect(solo.runOf('Second')!.outputs.single.single, containsPair('from', 21));
    expect(effects.performed, hasLength(1), reason: 'earlier steps did not run again');
    expect(await repository.executions('wf'), hasLength(1), reason: 'test runs are not history');
  });

  test('feeds the right branch and both inputs of a merge', () {
    final wf = Workflow(
      id: 'wf',
      name: 'Branches',
      nodes: [n('start', 'trigger.manual'), n('If', 'core.if'), n('Other', 'core.noop'), n('Merge', 'core.merge')],
      connections: [
        const Connection(from: 'start', to: 'If'),
        const Connection(from: 'start', to: 'Other'),
        const Connection(from: 'If', output: 1, to: 'Merge'),
        const Connection(from: 'Other', to: 'Merge', input: 1),
      ],
    );
    final outputs = {
      'If': [
        [
          {'yes': 1},
        ],
        [
          {'no': 1},
        ],
      ],
      'Other': [
        [
          {'other': 1},
        ],
      ],
    };
    final plan = soloRun(
      wf,
      'Merge',
      portOutput: (id, port) => outputs[id]?[port],
      allOutput: (id) => outputs[id]?.expand((i) => i).toList(),
    );
    final feeders = {for (final x in plan.workflow.nodes.where((x) => x.id.startsWith('__solo_in_'))) x.id: x.pinned};
    expect(feeders, {
      '__solo_in_0': [
        {'no': 1},
      ],
      '__solo_in_1': [
        {'other': 1},
      ],
    });
    expect(plan.workflow.connections.where((c) => c.to == 'Merge').map((c) => c.input).toSet(), {0, 1});
    // Earlier steps keep their names for $node references.
    expect(plan.workflow.nodes.map((x) => x.name), containsAll(['If', 'Other', 'start']));
  });

  test('explains what to do when there is no earlier data', () {
    final wf = Workflow(
      id: 'wf',
      name: 'Empty',
      nodes: [n('start', 'trigger.manual'), n('Fetch', 'http.request'), n('Use', 'core.noop')],
      connections: [const Connection(from: 'start', to: 'Fetch'), const Connection(from: 'Fetch', to: 'Use')],
    );
    expect(
      () => soloRun(wf, 'Use', portOutput: (_, _) => null, allOutput: (_) => null),
      throwsA(isA<SoloRunException>().having((e) => e.message, 'message', contains('no data from “Fetch” yet'))),
    );
    // Pinned test data counts as earlier output.
    final plan = soloRun(
      wf,
      'Use',
      portOutput: (id, _) => id == 'Fetch' ? [{'pinned': true}] : null,
      allOutput: (_) => null,
    );
    expect(plan.workflow.node('Use'), isNotNull);
  });
}
