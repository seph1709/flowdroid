import 'dart:math';

import 'json.dart';

/// Random ids that are short enough to read in the editor.
String newId([String prefix = '']) {
  final random = Random.secure();
  final suffix = List.generate(8, (_) => random.nextInt(36).toRadixString(36)).join();
  return '$prefix$suffix';
}

class WorkflowNode {
  WorkflowNode({
    required this.id,
    required this.name,
    required this.type,
    JsonMap? params,
    this.x = 0,
    this.y = 0,
    this.disabled = false,
    this.continueOnFail = false,
    this.pinned,
    this.retryOnFail = false,
    this.maxTries = 3,
    this.waitBetweenTries = 1000,
  }) : params = params ?? {};

  WorkflowNode.fromJson(JsonMap json)
    : id = asString(json['id']),
      name = asString(json['name'], asString(json['id'])),
      type = asString(json['type']),
      params = Map.of(asMap(json['params'])),
      x = asDouble(json['x']),
      y = asDouble(json['y']),
      disabled = asBool(json['disabled']),
      continueOnFail = asBool(json['continueOnFail']),
      pinned = json['pinned'] is List ? asMapList(json['pinned']) : null,
      retryOnFail = asBool(json['retryOnFail']),
      maxTries = asInt(json['maxTries'], 3),
      waitBetweenTries = asInt(json['waitBetweenTries'], 1000);

  final String id;
  String name;
  final String type;
  JsonMap params;
  double x;
  double y;
  bool disabled;
  bool continueOnFail;

  /// Output saved in the editor; test runs reuse it instead of running the node.
  List<JsonMap>? pinned;

  /// After a failed request, try again up to [maxTries] times, [waitBetweenTries] ms apart.
  bool retryOnFail;
  int maxTries;
  int waitBetweenTries;

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'params': params,
    'x': x,
    'y': y,
    'disabled': disabled,
    'continueOnFail': continueOnFail,
    if (pinned != null) 'pinned': pinned,
    if (retryOnFail) ...{'retryOnFail': true, 'maxTries': maxTries, 'waitBetweenTries': waitBetweenTries},
  };
}

class Connection {
  const Connection({required this.from, required this.to, this.output = 0, this.input = 0});

  Connection.fromJson(JsonMap json)
    : from = asString(json['from']),
      to = asString(json['to']),
      output = asInt(json['output']),
      input = asInt(json['input']);

  final String from;
  final int output;
  final String to;
  final int input;

  bool touches(String nodeId) => from == nodeId || to == nodeId;

  @override
  bool operator ==(Object other) =>
      other is Connection && other.from == from && other.output == output && other.to == to && other.input == input;

  @override
  int get hashCode => Object.hash(from, output, to, input);

  JsonMap toJson() => {'from': from, 'output': output, 'to': to, 'input': input};
}

/// A workflow as stored on the device. `toJson` is also what the core reads;
/// it ignores the editor-only fields (`x`, `y`, `active`, timestamps).
class Workflow {
  Workflow({
    required this.id,
    required this.name,
    List<WorkflowNode>? nodes,
    List<Connection>? connections,
    JsonMap? variables,
    this.active = false,
    this.errorWorkflowId,
    DateTime? updatedAt,
  }) : nodes = nodes ?? [],
       connections = connections ?? [],
       variables = variables ?? {},
       updatedAt = updatedAt ?? DateTime.now();

  Workflow.fromJson(JsonMap json)
    : id = asString(json['id']),
      name = asString(json['name'], 'Untitled'),
      nodes = asMapList(json['nodes']).map(WorkflowNode.fromJson).toList(),
      connections = asMapList(json['connections']).map(Connection.fromJson).toList(),
      variables = Map.of(asMap(json['variables'])),
      active = asBool(json['active']),
      errorWorkflowId = asMap(json['settings'])['errorWorkflow'] as String?,
      updatedAt = DateTime.tryParse(asString(json['updatedAt'])) ?? DateTime.now();

  final String id;
  String name;
  final List<WorkflowNode> nodes;
  final List<Connection> connections;
  JsonMap variables;
  bool active;

  /// Workflow to run (from its Error Trigger) when this one fails.
  String? errorWorkflowId;
  DateTime updatedAt;

  WorkflowNode? node(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Iterable<WorkflowNode> nodesOfType(String type) => nodes.where((n) => n.type == type && !n.disabled);

  /// A node name not used yet: `HTTP Request`, `HTTP Request 2`, ...
  String uniqueName(String base) {
    final taken = nodes.map((n) => n.name).toSet();
    if (!taken.contains(base)) return base;
    var i = 2;
    while (taken.contains('$base $i')) {
      i++;
    }
    return '$base $i';
  }

  void removeNode(String nodeId) {
    nodes.removeWhere((n) => n.id == nodeId);
    connections.removeWhere((c) => c.touches(nodeId));
  }

  JsonMap toJson() => {
    'id': id,
    'name': name,
    'active': active,
    'updatedAt': updatedAt.toIso8601String(),
    'variables': variables,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'connections': connections.map((c) => c.toJson()).toList(),
    if (errorWorkflowId != null) 'settings': {'errorWorkflow': errorWorkflowId},
  };

  Workflow copy() => Workflow.fromJson(toJson());
}
