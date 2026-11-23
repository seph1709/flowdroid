import 'dart:async';
import 'dart:convert';

import '../core/execution_state.dart';
import '../core/flowcore.dart';
import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../data/repository.dart';
import 'effects.dart';

/// Lets the person stop a run. The run ends at once (the step in progress may
/// still finish in the background, but nothing after it runs).
class RunCancel {
  final _stopped = Completer<void>();

  bool get isCancelled => _stopped.isCompleted;

  Future<void> get whenCancelled => _stopped.future;

  void cancel() {
    if (!_stopped.isCompleted) _stopped.complete();
  }
}

/// What a stopped run reports as its error.
const stoppedByYou = 'Stopped by you';

/// Drives one execution: the core decides what runs next; whenever it waits
/// on an effect, the runner performs it and resumes the core with the result.
class WorkflowRunner {
  WorkflowRunner({required this.core, required this.effects, required this.repository, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// How deep workflows may call each other (Execute Workflow, error workflows).
  static const maxDepth = 5;
  static const _depthKey = #flowdroidRunDepth;

  final FlowCore core;
  final EffectHandler effects;
  final Repository repository;
  final DateTime Function() _clock;

  /// How many workflows are running inside each other at this point (0 outside any run).
  static int get currentDepth => (Zone.current[_depthKey] as int?) ?? 0;

  /// Runs [workflow] from [triggerNodeId] and saves the execution to history.
  ///
  /// [onProgress] sees every intermediate state (useful to highlight the node
  /// that is waiting). [respond] answers the webhook that started the run.
  /// Manual runs reuse pinned node output unless [usePinned] says otherwise.
  /// With [keep] false the run is not saved to history (single-step tests).
  Future<ExecutionRecord> run(
    Workflow workflow, {
    required String triggerNodeId,
    required TriggerMode mode,
    List<JsonMap> items = const [],
    void Function(ExecutionState state)? onProgress,
    WebhookResponder? respond,
    bool? usePinned,
    bool keep = true,
    RunCancel? cancel,
  }) {
    final depth = currentDepth + 1;
    return runZoned(
      () => _run(
        workflow,
        triggerNodeId,
        mode,
        items,
        onProgress,
        respond,
        usePinned ?? mode == TriggerMode.manual,
        keep,
        cancel,
      ),
      zoneValues: {_depthKey: depth},
    );
  }

  Future<ExecutionRecord> _run(
    Workflow workflow,
    String triggerNodeId,
    TriggerMode mode,
    List<JsonMap> items,
    void Function(ExecutionState state)? onProgress,
    WebhookResponder? respond,
    bool usePinned,
    bool keep,
    RunCancel? cancel,
  ) async {
    final startedAt = _clock();
    final workflowJson = jsonEncode({...workflow.toJson(), if (usePinned) 'usePinnedData': true});
    ExecutionRecord finish(ExecutionStatus status, String? error, List<NodeRunRecord> runs) => ExecutionRecord(
      id: newId('ex_'),
      workflowId: workflow.id,
      workflowName: workflow.name,
      mode: mode,
      status: status,
      startedAt: startedAt,
      finishedAt: _clock(),
      error: error,
      runs: runs,
    );

    ExecutionRecord record;
    try {
      var state = core.startExecution(workflowJson, triggerNodeId, items, startedAt);
      var stopped = false;
      while (state.isWaiting) {
        onProgress?.call(state);
        final work = effects.perform(state.pendingEffect ?? const {}, respond: respond);
        final JsonMap? result = cancel == null
            ? await work
            : await Future.any<JsonMap?>([work, cancel.whenCancelled.then((_) => null)]);
        if (result == null || (cancel?.isCancelled ?? false)) {
          stopped = true;
          break;
        }
        state = core.resumeExecution(workflowJson, state, result, _clock());
      }
      onProgress?.call(state);
      record = stopped
          ? finish(ExecutionStatus.error, stoppedByYou, state.runs)
          : finish(state.status, state.error, state.runs);
    } on FlowCoreException catch (e) {
      record = finish(ExecutionStatus.error, e.message, const []);
    }
    // Test runs of a single step ([keep] false) aren't history and start no error workflow.
    if (!keep) return record;
    await repository.saveExecution(record);
    if (record.status == ExecutionStatus.error && mode != TriggerMode.error && record.error != stoppedByYou) {
      await _runErrorWorkflow(workflow, record);
    }
    return record;
  }

  /// Runs another workflow from its "When Called by a Workflow" trigger and
  /// returns the output of the last node that ran.
  Future<List<JsonMap>> runSubWorkflow(String workflowId, List<JsonMap> items) async {
    if (currentDepth >= maxDepth) {
      throw SubWorkflowException('workflows call each other more than $maxDepth levels deep');
    }
    final target = await repository.workflow(workflowId);
    if (target == null) throw SubWorkflowException('the workflow to call no longer exists');
    final trigger = target.nodesOfType('trigger.subworkflow').firstOrNull;
    if (trigger == null) {
      throw SubWorkflowException('“${target.name}” has no “When Called by a Workflow” trigger');
    }
    final record = await run(target, triggerNodeId: trigger.id, mode: TriggerMode.subworkflow, items: items);
    if (record.status == ExecutionStatus.error) {
      throw SubWorkflowException('“${target.name}” failed: ${record.error ?? 'unknown error'}');
    }
    final last = record.runs.lastOrNull;
    return last == null ? const [] : last.outputs.expand((items) => items).toList();
  }

  Future<void> _runErrorWorkflow(Workflow failed, ExecutionRecord record) async {
    final id = failed.errorWorkflowId;
    if (id == null || id == failed.id || currentDepth >= maxDepth) return;
    final target = await repository.workflow(id);
    final trigger = target?.nodesOfType('trigger.error').firstOrNull;
    if (target == null || trigger == null) return;
    final lastNode = record.runs.lastOrNull;
    await run(
      target,
      triggerNodeId: trigger.id,
      mode: TriggerMode.error,
      items: [
        {
          'workflow': {'id': failed.id, 'name': failed.name},
          'execution': {
            'id': record.id,
            'error': record.error,
            'lastNode': lastNode?.name,
            'mode': record.mode.name,
            'startedAt': record.startedAt.toUtc().toIso8601String(),
          },
        },
      ],
    );
  }
}

class SubWorkflowException implements Exception {
  const SubWorkflowException(this.message);

  final String message;

  @override
  String toString() => message;
}
