import '../core/execution_state.dart';
import '../core/json.dart';

/// How an execution was started.
enum TriggerMode {
  manual,
  schedule,
  webhook,
  telegram,
  subworkflow,
  error,
  sms,
  notification,
  phone,
  place,
  share,
  tile,
  rss,
  email;

  /// Unknown names (from a newer version) read as manual.
  static TriggerMode parse(String name) => values.asNameMap()[name] ?? manual;
}

/// A finished (or failed) execution, kept for the history screen.
class ExecutionRecord {
  ExecutionRecord({
    required this.id,
    required this.workflowId,
    required this.workflowName,
    required this.mode,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.error,
    required this.runs,
  });

  ExecutionRecord.fromJson(JsonMap json)
    : id = asString(json['id']),
      workflowId = asString(json['workflowId']),
      workflowName = asString(json['workflowName']),
      mode = TriggerMode.parse(asString(json['mode'], 'manual')),
      status = ExecutionStatus.values.byName(asString(json['status'], 'error')),
      startedAt = DateTime.parse(asString(json['startedAt'])),
      finishedAt = DateTime.parse(asString(json['finishedAt'])),
      error = json['error'] as String?,
      runs = asMapList(json['runs']).map(NodeRunRecord.fromJson).toList();

  final String id;
  final String workflowId;
  final String workflowName;
  final TriggerMode mode;
  final ExecutionStatus status;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? error;
  final List<NodeRunRecord> runs;

  Duration get duration => finishedAt.difference(startedAt);

  bool get succeeded => status == ExecutionStatus.success;

  /// The most recent run of [nodeId], if it ran.
  NodeRunRecord? runOf(String nodeId) {
    for (final run in runs.reversed) {
      if (run.nodeId == nodeId) return run;
    }
    return null;
  }

  JsonMap toJson() => {
    'id': id,
    'workflowId': workflowId,
    'workflowName': workflowName,
    'mode': mode.name,
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'error': error,
    'runs': runs.map((r) => r.toJson()).toList(),
  };
}
