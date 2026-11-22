import 'dart:convert';

import 'json.dart';

enum ExecutionStatus { running, waiting, success, error }

/// One node run inside an execution.
class NodeRunRecord {
  NodeRunRecord.fromJson(JsonMap json)
    : nodeId = asString(json['node']),
      name = asString(json['name']),
      at = DateTime.fromMillisecondsSinceEpoch(asInt(json['at']), isUtc: true),
      error = json['error'] as String?,
      outputs = asList(json['output']).map(asMapList).toList();

  final String nodeId;
  final String name;
  final DateTime at;
  final String? error;

  /// Items per output port.
  final List<List<JsonMap>> outputs;

  int get itemCount => outputs.fold(0, (sum, items) => sum + items.length);

  JsonMap toJson() => {
    'node': nodeId,
    'name': name,
    'at': at.millisecondsSinceEpoch,
    'error': error,
    'output': outputs,
  };
}

/// The core's execution state. [raw] is passed back verbatim to resume.
class ExecutionState {
  ExecutionState(this.json) : raw = jsonEncode(json);

  final JsonMap json;
  final String raw;

  ExecutionStatus get status => ExecutionStatus.values.byName(asString(json['status'], 'error'));

  bool get isWaiting => status == ExecutionStatus.waiting;

  String? get error => json['error'] as String?;

  /// The effect the host must perform before resuming, e.g. `{type: http, requests: [...]}`.
  JsonMap? get pendingEffect {
    final pending = json['pending'];
    return pending is Map ? asMap(asMap(pending)['effect']) : null;
  }

  String? get pendingNodeId {
    final pending = json['pending'];
    return pending is Map ? asString(asMap(pending)['node']) : null;
  }

  List<NodeRunRecord> get runs => asMapList(json['runs']).map(NodeRunRecord.fromJson).toList();

  /// The latest output of each node, by node name.
  Map<String, List<JsonMap>> get lastOutputs =>
      asMap(json['last']).map((name, items) => MapEntry(name, asMapList(items)));
}
