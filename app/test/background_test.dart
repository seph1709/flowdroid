import 'dart:io';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/runtime/background_health.dart';
import 'package:flowdroid/runtime/oem_guides.dart';
import 'package:flowdroid/runtime/phone/phone_events.dart';
import 'package:flowdroid/runtime/runner.dart';
import 'package:flowdroid/runtime/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('the heartbeat log records pauses longer than five minutes', () async {
    final dir = await Directory.systemTemp.createTemp('health');
    var now = DateTime(2026, 11, 22, 8);
    var uptime = const Duration(days: 30);
    final health = BackgroundHealth(dir, clock: () => now, uptime: () => uptime);

    expect(await health.lastBeat(), isNull);
    expect(await health.pausedNow(), isFalse);
    await health.beat();
    now = now.add(const Duration(minutes: 1));
    await health.beat();
    expect(await health.recentPauses(), isEmpty);

    now = now.add(const Duration(minutes: 47));
    expect(await health.pausedNow(), isTrue);
    await health.beat();
    final pauses = await health.recentPauses();
    expect(pauses.single.length, const Duration(minutes: 47));
    expect(await health.pausedNow(), isFalse);

    // Turning Keep running off and on again is not a pause.
    await health.restart();
    now = now.add(const Duration(hours: 3));
    await health.beat();
    expect(await health.recentPauses(), hasLength(1));

    // The phone was off for an hour: it came back 10 minutes ago.
    now = now.add(const Duration(hours: 1));
    uptime = const Duration(minutes: 10);
    await health.beat();
    expect(await health.recentPauses(), hasLength(1), reason: 'a restart is not a pause');

    now = now.add(const Duration(days: 2));
    expect(await health.recentPauses(), isEmpty, reason: 'only the last day counts');
  });

  test('nextDue finds the earliest schedule, never in the past', () async {
    final repository = await tempRepository();
    var now = DateTime.utc(2026, 11, 22, 8);
    final runner = WorkflowRunner(core: core, effects: FakeEffects(), repository: repository, clock: () => now);
    final scheduler = Scheduler(core: core, repository: repository, runner: runner, clock: () => now);
    expect(await scheduler.nextDue(), isNull);

    Workflow wf(String id, JsonMap params, {bool active = true}) => Workflow(
      id: id,
      name: id,
      active: active,
      nodes: [WorkflowNode(id: 't', name: 'T', type: 'trigger.schedule', params: params)],
    );
    await repository.saveWorkflow(wf('a', {'mode': 'interval', 'minutes': 30}));
    await repository.saveWorkflow(wf('b', {'mode': 'interval', 'minutes': 10}));
    await repository.saveWorkflow(wf('c', {'mode': 'interval', 'minutes': 1}, active: false));
    await scheduler.tick(); // starts the clocks
    expect(await scheduler.nextDue(), now.add(const Duration(minutes: 10)));

    now = now.add(const Duration(minutes: 25));
    expect(await scheduler.nextDue(), now, reason: 'overdue means now');
  });

  test('a tick event from the wake-up alarm runs the schedules', () async {
    final repository = await tempRepository();
    final dir = await Directory.systemTemp.createTemp('events');
    var ticks = 0;
    final events = PhoneEvents(
      dataDir: dir,
      repository: repository,
      runner: WorkflowRunner(core: core, effects: FakeEffects(), repository: repository),
      onTick: () async => ticks++,
    );
    await events.dispatch({'type': 'tick'});
    expect(ticks, 1);
  });

  test('phone makers get their own steps; stock Android needs none', () {
    expect(guideFor('HUAWEI').name, 'Huawei');
    expect(guideFor('huawei').steps.join(' '), contains('Run in background'));
    expect(guideFor('redmi').name, 'Xiaomi');
    expect(guideFor('honor').autostartLabel, isNotNull);
    expect(guideFor('samsung').lockInRecents, isFalse);
    expect(guideFor('google').isStock, isTrue);
    expect(guideFor('motorola').isStock, isTrue);
  });
}
