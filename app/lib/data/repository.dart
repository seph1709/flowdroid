import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/json.dart';
import '../core/workflow.dart';
import 'execution_record.dart';
import 'json_file_store.dart';

/// Workflows, their execution history and scheduler bookkeeping, on disk.
///
/// Notifies listeners whenever workflows or executions change, so screens
/// can rebuild without polling.
class Repository extends ChangeNotifier {
  Repository(Directory root)
    : _workflows = JsonFileStore(Directory('${root.path}/workflows')),
      _executionsRoot = Directory('${root.path}/executions'),
      _schedule = JsonFileStore(Directory('${root.path}/schedule')),
      _state = JsonFileStore(Directory('${root.path}/state'));

  /// Executions kept per workflow; older ones are pruned.
  static const historyLimit = 50;

  final JsonFileStore _workflows;
  final Directory _executionsRoot;
  final JsonFileStore _schedule;
  final JsonFileStore _state;

  /// Small runtime bookkeeping (e.g. a Telegram update offset), by key.
  Future<JsonMap?> readState(String key) => _state.read(_safeKey(key));

  Future<void> writeState(String key, JsonMap value) => _state.write(_safeKey(key), value);

  static String _safeKey(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  JsonFileStore _executions(String workflowId) => JsonFileStore(Directory('${_executionsRoot.path}/$workflowId'));

  Future<List<Workflow>> workflows() async {
    final list = (await _workflows.readAll()).map(Workflow.fromJson).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  Future<Workflow?> workflow(String id) async {
    final json = await _workflows.read(id);
    return json == null ? null : Workflow.fromJson(json);
  }

  Future<void> saveWorkflow(Workflow wf) async {
    wf.updatedAt = DateTime.now();
    await _workflows.write(wf.id, wf.toJson());
    notifyListeners();
  }

  Future<void> deleteWorkflow(String id) async {
    await _workflows.delete(id);
    await _executions(id).deleteAll();
    await _schedule.delete(id);
    notifyListeners();
  }

  /// Newest first.
  Future<List<ExecutionRecord>> executions(String workflowId) async {
    final list = (await _executions(workflowId).readAll()).map(ExecutionRecord.fromJson).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return list;
  }

  Future<ExecutionRecord?> latestExecution(String workflowId) async {
    final list = await executions(workflowId);
    return list.isEmpty ? null : list.first;
  }

  Future<void> saveExecution(ExecutionRecord record) async {
    final store = _executions(record.workflowId);
    await store.write(record.id, record.toJson());
    final all = await executions(record.workflowId);
    for (final old in all.skip(historyLimit)) {
      await store.delete(old.id);
    }
    notifyListeners();
  }

  /// Tells listeners to re-read from disk, e.g. after the background service ran a workflow.
  void reload() => notifyListeners();

  Future<void> clearExecutions(String workflowId) async {
    await _executions(workflowId).deleteAll();
    notifyListeners();
  }

  /// When the scheduler last fired [triggerId] of [workflowId].
  Future<DateTime?> lastScheduledRun(String workflowId, String triggerId) async {
    final json = await _schedule.read(workflowId) ?? const {};
    return DateTime.tryParse(asString(json[triggerId]));
  }

  Future<void> setLastScheduledRun(String workflowId, String triggerId, DateTime at) async {
    final json = {...?await _schedule.read(workflowId), triggerId: at.toUtc().toIso8601String()};
    await _schedule.write(workflowId, json);
  }
}
