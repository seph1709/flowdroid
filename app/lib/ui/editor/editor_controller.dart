import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../app_services.dart';
import '../../runtime/runner.dart';
import '../../core/execution_state.dart';
import '../../core/json.dart';
import '../../core/node_catalog.dart';
import '../../core/layout.dart';
import '../../core/solo_run.dart';
import '../../core/workflow.dart';

export '../../core/layout.dart' show canvasSize;
import '../../data/execution_record.dart';

/// An output port waiting to be connected to an input.
typedef PortRef = ({String nodeId, int output});

/// Editing state of one workflow: the document, selection, connect mode and the last run.
/// Changes are saved automatically shortly after they happen.
class EditorController extends ChangeNotifier {
  EditorController({required this.services, required this.workflow, this.lastExecution});

  static const _saveDelay = Duration(milliseconds: 600);

  /// Keeps nodes (and their port touch targets) inside the canvas.
  static const _margin = 24.0;

  final AppServices services;
  final Workflow workflow;
  ExecutionRecord? lastExecution;

  /// Output port the user tapped, while choosing where to connect it.
  PortRef? connecting;

  /// Node the running execution is waiting on (HTTP call, notification, ...).
  String? activeNodeId;
  bool running = false;

  /// Stops the run in progress; null when nothing runs.
  RunCancel? _cancel;

  /// Steps finished so far in the running execution.
  int stepsDone = 0;
  List<String> issues = const [];
  Timer? _saveTimer;

  // ---- undo and redo ----

  static const _historyLimit = 50;

  /// Typing in one field, or dragging one node, within this time is one undo step.
  static const _coalesce = Duration(milliseconds: 1500);

  final _undo = <JsonMap>[];
  final _redo = <JsonMap>[];
  String? _lastEditKey;
  DateTime _lastEditAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastGroup;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Remembers the workflow before an edit; repeated edits of the same [key] merge into one step.
  void _checkpoint([String? key, String? group]) {
    final now = DateTime.now();
    final sameGroup = group != null && group == _lastGroup;
    _lastGroup = group;
    if (sameGroup) return;
    final merge = key != null && key == _lastEditKey && now.difference(_lastEditAt) < _coalesce;
    _lastEditKey = key;
    _lastEditAt = now;
    if (merge) return;
    _undo.add(workflow.toJson());
    if (_undo.length > _historyLimit) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() => _step(_undo, _redo);

  void redo() => _step(_redo, _undo);

  void _step(List<JsonMap> from, List<JsonMap> to) {
    if (from.isEmpty) return;
    to.add(workflow.toJson());
    final snapshot = Workflow.fromJson(from.removeLast());
    workflow.nodes
      ..clear()
      ..addAll(snapshot.nodes);
    workflow.connections
      ..clear()
      ..addAll(snapshot.connections);
    workflow
      ..name = snapshot.name
      ..variables = snapshot.variables
      ..errorWorkflowId = snapshot.errorWorkflowId;
    _lastEditKey = null;
    _lastGroup = null;
    connecting = null;
    _changed();
  }

  /// Applies [edit] to the workflow directly. Edits with the same [group] (one
  /// assistant reply) undo as one step.
  T batch<T>(T Function(Workflow workflow) edit, {String? group}) {
    _checkpoint(null, group);
    try {
      return edit(workflow);
    } finally {
      connecting = null;
      _changed();
    }
  }

  NodeType? typeOf(WorkflowNode node) => services.nodeType(node.type);

  List<String> outputLabels(WorkflowNode node) => typeOf(node)?.outputLabels(node.params) ?? const ['main'];

  int inputCount(WorkflowNode node) => typeOf(node)?.inputs ?? 1;

  Iterable<WorkflowNode> get triggers => workflow.nodes.where((n) => typeOf(n)?.isTrigger ?? false);

  // ---- editing ----

  WorkflowNode addNode(NodeType type, {required double x, required double y}) {
    _checkpoint();
    final node = WorkflowNode(
      id: newId('n_'),
      name: workflow.uniqueName(type.label),
      type: type.type,
      params: type.defaultParams(),
      x: x,
      y: y,
    );
    workflow.nodes.add(node);
    final from = connecting;
    if (from != null && type.inputs > 0) _connect(from, node.id, 0);
    connecting = null;
    _changed();
    return node;
  }

  void moveNode(WorkflowNode node, Offset delta) {
    _checkpoint('move:${node.id}');
    node
      ..x = (node.x + delta.dx).clamp(_margin, canvasSize.width - 250)
      ..y = (node.y + delta.dy).clamp(_margin, canvasSize.height - 120);
    notifyListeners();
    _scheduleSave();
  }

  /// Lays the steps out top to bottom in layers (triggers first), branches side by side.
  void tidyUp() {
    _checkpoint();
    layoutVertically(workflow, (node) => typeOf(node)?.isTrigger ?? false);
    _changed();
  }

  void beginConnect(String nodeId, int output) {
    connecting = (nodeId: nodeId, output: output);
    notifyListeners();
  }

  void cancelConnect() {
    connecting = null;
    notifyListeners();
  }

  /// Completes connect mode on [nodeId]'s [input]; returns false for invalid targets.
  bool completeConnect(String nodeId, [int input = 0]) {
    final from = connecting;
    connecting = null;
    final target = workflow.node(nodeId);
    final ok = from != null && target != null && from.nodeId != nodeId && inputCount(target) > input;
    if (ok) {
      _checkpoint();
      _connect(from, nodeId, input);
    }
    notifyListeners();
    if (ok) _changed();
    return ok;
  }

  void _connect(PortRef from, String to, int input) {
    final connection = Connection(from: from.nodeId, output: from.output, to: to, input: input);
    if (!workflow.connections.contains(connection)) workflow.connections.add(connection);
  }

  void disconnect(Connection connection) {
    _checkpoint();
    workflow.connections.remove(connection);
    _changed();
  }

  void deleteNode(WorkflowNode node) {
    _checkpoint();
    workflow.removeNode(node.id);
    _changed();
  }

  WorkflowNode duplicateNode(WorkflowNode node) {
    _checkpoint();
    final copy = WorkflowNode.fromJson({
      ...node.toJson(),
      'id': newId('n_'),
      'name': workflow.uniqueName(node.name),
      'x': node.x + 40,
      'y': node.y + 100,
    });
    workflow.nodes.add(copy);
    _changed();
    return copy;
  }

  void renameNode(WorkflowNode node, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == node.name) return;
    _checkpoint('name:${node.id}');
    node.name = workflow.uniqueName(trimmed);
    _changed();
  }

  void setParam(WorkflowNode node, String key, Object? value) {
    _checkpoint('param:${node.id}:$key');
    node.params[key] = value;
    _changed();
  }

  /// Replaces several parameters as one undo step (e.g. from a cURL import).
  void setParams(WorkflowNode node, JsonMap params) {
    _checkpoint();
    node.params.addAll(params);
    _changed();
  }

  /// Pins [items] typed or pasted by the user as [node]'s test output.
  void setPinned(WorkflowNode node, List<JsonMap> items) {
    _checkpoint();
    node.pinned = items;
    _changed();
  }

  void setFlags(WorkflowNode node, {bool? disabled, bool? continueOnFail}) {
    _checkpoint();
    node
      ..disabled = disabled ?? node.disabled
      ..continueOnFail = continueOnFail ?? node.continueOnFail;
    _changed();
  }

  void rename(String name) {
    if (name.trim().isEmpty) return;
    _checkpoint('workflow-name');
    workflow.name = name.trim();
    _changed();
  }

  void setActive(bool active) {
    workflow.active = active;
    _changed();
  }

  /// Retry after a failed request: [maxTries] tries in all, [waitMs] apart.
  void setRetry(WorkflowNode node, {required bool enabled, int? maxTries, int? waitMs}) {
    _checkpoint();
    node
      ..retryOnFail = enabled
      ..maxTries = maxTries ?? node.maxTries
      ..waitBetweenTries = waitMs ?? node.waitBetweenTries;
    _changed();
  }

  /// Saves [node]'s last output so test runs reuse it instead of running the node again.
  void pinOutput(WorkflowNode node) {
    final run = lastRunOf(node);
    if (run == null) return;
    _checkpoint();
    node.pinned = run.outputs.expand((items) => items).toList();
    _changed();
  }

  void unpinOutput(WorkflowNode node) {
    _checkpoint();
    node.pinned = null;
    _changed();
  }

  void setErrorWorkflow(String? id) {
    _checkpoint();
    workflow.errorWorkflowId = id == null || id.isEmpty ? null : id;
    _changed();
  }

  void setVariables(JsonMap variables) {
    _checkpoint();
    workflow.variables = variables;
    _changed();
  }

  // ---- running ----

  /// Runs from [trigger] (or the first trigger) and keeps the result for the output panels.
  Future<ExecutionRecord?> run([WorkflowNode? trigger]) async {
    final start = trigger ?? triggers.firstOrNull;
    if (start == null || running) return null;
    await save();
    running = true;
    stepsDone = 0;
    final cancel = _cancel = RunCancel();
    notifyListeners();
    try {
      final record = await services.runner.run(
        workflow,
        triggerNodeId: start.id,
        mode: TriggerMode.manual,
        items: [_sampleTriggerItem(start)],
        cancel: cancel,
        onProgress: (state) {
          activeNodeId = state.isWaiting ? state.pendingNodeId : null;
          stepsDone = asList(state.json['runs']).length;
          notifyListeners();
        },
      );
      lastExecution = record;
      return record;
    } finally {
      running = false;
      activeNodeId = null;
      _cancel = null;
      notifyListeners();
    }
  }

  /// Runs only [node], on the input its earlier steps produced in the last run
  /// (or their pinned data). The result replaces [node]'s output in the last
  /// run, so the canvas and Output tab show it; nothing is added to history.
  /// Returns why it couldn't run, or null.
  Future<String?> runStep(WorkflowNode node) async {
    if (running) return 'a run is already in progress';
    if (typeOf(node)?.isTrigger ?? false) {
      final record = await run(node);
      return record == null ? 'could not start' : null;
    }
    final record = lastExecution;
    List<JsonMap>? flat(String id) {
      final r = record?.runOf(id);
      if (r != null) return r.outputs.expand((i) => i).toList();
      return workflow.node(id)?.pinned;
    }

    final SoloRun plan;
    try {
      plan = soloRun(
        workflow,
        node.id,
        portOutput: (id, output) {
          final r = record?.runOf(id);
          if (r != null) return output < r.outputs.length ? r.outputs[output] : const [];
          return workflow.node(id)?.pinned;
        },
        allOutput: flat,
      );
    } on SoloRunException catch (e) {
      return e.message;
    }
    running = true;
    activeNodeId = node.id;
    final cancel = _cancel = RunCancel();
    notifyListeners();
    try {
      final solo = await services.runner.run(
        plan.workflow,
        triggerNodeId: plan.startId,
        mode: TriggerMode.manual,
        items: const [{}],
        usePinned: true,
        keep: false,
        cancel: cancel,
      );
      if (cancel.isCancelled) return stoppedByYou;
      final result = solo.runOf(node.id);
      if (result == null) return solo.error ?? 'the step did not run: it received no items';
      final base = lastExecution;
      final runs = [...?base?.runs.where((r) => r.nodeId != node.id), result];
      final failed = runs.any((r) => r.error != null);
      lastExecution = ExecutionRecord(
        id: base?.id ?? solo.id,
        workflowId: workflow.id,
        workflowName: workflow.name,
        mode: base?.mode ?? TriggerMode.manual,
        status: failed ? ExecutionStatus.error : ExecutionStatus.success,
        startedAt: base?.startedAt ?? solo.startedAt,
        finishedAt: solo.finishedAt,
        error: result.error ?? (failed ? base?.error : null),
        runs: runs,
      );
      return null;
    } finally {
      running = false;
      activeNodeId = null;
      _cancel = null;
      notifyListeners();
    }
  }

  /// Arguments shaped like the MCP Tool Trigger's schema: `"test"` for text, 1 for numbers, and so on.
  static JsonMap sampleArguments(Object? schema) {
    Object? parsed = schema;
    if (schema is String) {
      try {
        parsed = jsonDecode(schema);
      } on FormatException {
        parsed = null;
      }
    }
    return {
      for (final MapEntry(:key, :value) in asMap(asMap(parsed)['properties']).entries)
        key: switch (asMap(value)['type']) {
          'number' || 'integer' => 1,
          'boolean' => true,
          'array' => <Object?>[],
          'object' => <String, Object?>{},
          _ => 'test',
        },
    };
  }

  /// Stops the run (or single-step run) in progress.
  void stop() => _cancel?.cancel();

  /// A manual run of a webhook or schedule trigger gets an item shaped like the real one.
  JsonMap _sampleTriggerItem(WorkflowNode trigger) => switch (trigger.type) {
    'trigger.webhook' => {
      'method': asString(trigger.params['method'], 'POST'),
      'path': asString(trigger.params['path']),
      'headers': <String, Object?>{},
      'query': <String, Object?>{},
      'body': {'test': true},
    },
    'trigger.schedule' => {'timestamp': DateTime.now().toUtc().toIso8601String()},
    'trigger.mcp' => sampleArguments(trigger.params['inputSchema']),
    _ => {},
  };

  /// The status a node shows on the canvas after the last run.
  NodeRunStatus statusOf(WorkflowNode node) {
    if (activeNodeId == node.id) return NodeRunStatus.running;
    final run = lastExecution?.runOf(node.id);
    if (run == null) return NodeRunStatus.idle;
    return run.error == null ? NodeRunStatus.success : NodeRunStatus.error;
  }

  NodeRunRecord? lastRunOf(WorkflowNode node) => lastExecution?.runOf(node.id);

  /// Variables for previewing expressions in [node]: the first item it received last run.
  JsonMap previewContext(WorkflowNode node) {
    final record = lastExecution;
    JsonMap input = {};
    for (final c in workflow.connections.where((c) => c.to == node.id)) {
      final upstream = record?.runOf(c.from);
      final items = upstream == null || c.output >= upstream.outputs.length
          ? const <JsonMap>[]
          : upstream.outputs[c.output];
      if (items.isNotEmpty) {
        input = items.first;
        break;
      }
    }
    final nodes = <String, Object?>{};
    for (final run in record?.runs ?? const <NodeRunRecord>[]) {
      final all = run.outputs.expand((items) => items).toList();
      nodes[run.name] = {'json': all.firstOrNull, 'all': all};
    }
    return {
      r'$json': input,
      r'$index': 0,
      r'$items': [input],
      r'$node': nodes,
      r'$vars': workflow.variables,
      r'$workflow': {'id': workflow.id, 'name': workflow.name},
      r'$now': DateTime.now().toUtc().toIso8601String(),
    };
  }

  // ---- saving ----

  void _changed() {
    issues = services.core.validateWorkflow(workflow.toJson());
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, save);
  }

  Future<void> save() async {
    _saveTimer?.cancel();
    await services.repository.saveWorkflow(workflow);
  }

  void validate() {
    issues = services.core.validateWorkflow(workflow.toJson());
    notifyListeners();
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive ?? false) unawaited(save());
    super.dispose();
  }
}

enum NodeRunStatus { idle, running, success, error }
