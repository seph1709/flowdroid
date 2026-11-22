import '../core/flowcore.dart';
import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../data/repository.dart';
import 'runner.dart';

/// Decides which Schedule Triggers are due and runs them.
///
/// [tick] is called every minute while the app is open, and by WorkManager
/// roughly every 15 minutes in the background, so a cron schedule fires late
/// at worst by the background interval, never twice for the same slot.
class Scheduler {
  Scheduler({required this.core, required this.repository, required this.runner, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final FlowCore core;
  final Repository repository;
  final WorkflowRunner runner;
  final DateTime Function() _clock;

  /// Runs every due schedule; returns how many executions started.
  Future<int> tick() async {
    final now = _clock();
    var started = 0;
    for (final wf in (await repository.workflows()).where((w) => w.active)) {
      for (final trigger in wf.nodesOfType('trigger.schedule')) {
        final last = await repository.lastScheduledRun(wf.id, trigger.id);
        if (last == null) {
          // First sight of this schedule: start counting from now instead of firing at once.
          await repository.setLastScheduledRun(wf.id, trigger.id, now);
          continue;
        }
        final due = nextRun(trigger, last);
        if (due == null || due.isAfter(now)) continue;
        await repository.setLastScheduledRun(wf.id, trigger.id, now);
        await runner.run(
          wf,
          triggerNodeId: trigger.id,
          mode: TriggerMode.schedule,
          items: [
            {'timestamp': now.toUtc().toIso8601String(), 'scheduledFor': due.toUtc().toIso8601String()},
          ],
        );
        started++;
      }
    }
    return started;
  }

  /// The earliest time any active schedule is due next; null when there are none.
  Future<DateTime?> nextDue() async {
    final now = _clock();
    DateTime? best;
    for (final wf in (await repository.workflows()).where((w) => w.active)) {
      for (final trigger in wf.nodesOfType('trigger.schedule')) {
        final last = await repository.lastScheduledRun(wf.id, trigger.id) ?? now;
        final due = nextRun(trigger, last);
        if (due == null) continue;
        final at = due.isBefore(now) ? now : due;
        if (best == null || at.isBefore(best)) best = at;
      }
    }
    return best;
  }

  /// When [trigger] fires next after [after]; null for an invalid or impossible schedule.
  DateTime? nextRun(WorkflowNode trigger, DateTime after) {
    if (asString(trigger.params['mode'], 'interval') == 'cron') {
      try {
        return core.nextCronRun(asString(trigger.params['cron']), after, after.toLocal().timeZoneOffset);
      } on FlowCoreException {
        return null;
      }
    }
    final minutes = asDouble(trigger.params['minutes'], 15);
    if (minutes <= 0) return null;
    return after.add(Duration(seconds: (minutes * 60).round()));
  }
}
