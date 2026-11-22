import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  Workflow scheduled(JsonMap params) => Workflow(
    id: 'wf_sched',
    name: 'Scheduled',
    active: true,
    nodes: [
      WorkflowNode(id: 'tick', name: 'Tick', type: 'trigger.schedule', params: params),
      WorkflowNode(id: 'buzz', name: 'Buzz', type: 'android.vibrate'),
    ],
    connections: [const Connection(from: 'tick', to: 'buzz')],
  );

  test('interval schedules wait a full interval, then fire once per interval', () async {
    final repository = await tempRepository();
    final effects = FakeEffects();
    var now = DateTime.utc(2026, 11, 21, 8);
    final runner = WorkflowRunner(core: core, effects: effects, repository: repository, clock: () => now);
    final scheduler = Scheduler(core: core, repository: repository, runner: runner, clock: () => now);
    await repository.saveWorkflow(scheduled({'mode': 'interval', 'minutes': 15}));

    expect(await scheduler.tick(), 0, reason: 'first sight only starts the clock');
    now = now.add(const Duration(minutes: 14));
    expect(await scheduler.tick(), 0);
    now = now.add(const Duration(minutes: 1));
    expect(await scheduler.tick(), 1);
    expect(await scheduler.tick(), 0, reason: 'never twice for the same slot');
    expect(effects.performed.single['type'], 'vibrate');
  });

  test('cron schedules use the core to find the next slot', () async {
    final repository = await tempRepository();
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository);
    final scheduler = Scheduler(core: core, repository: repository, runner: runner);
    final trigger = scheduled({'mode': 'cron', 'cron': '30 9 * * *'}).nodes.first;
    final after = DateTime.utc(2026, 11, 21, 10);
    final next = scheduler.nextRun(trigger, after);
    expect(next, isNotNull);
    expect(next!.isAfter(after), isTrue);
    expect(next.difference(after), lessThanOrEqualTo(const Duration(days: 1)));
    expect(scheduler.nextRun(scheduled({'mode': 'cron', 'cron': 'nonsense'}).nodes.first, after), isNull);
  });
}
