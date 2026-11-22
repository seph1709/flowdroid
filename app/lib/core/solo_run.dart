import 'json.dart';
import 'workflow.dart';

/// Why a single step can't be run on its own yet.
class SoloRunException implements Exception {
  const SoloRunException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A small workflow that runs only one step, on the data its earlier steps
/// produced last time, so testing a step never means running everything before it.
class SoloRun {
  const SoloRun(this.workflow, this.startId);

  final Workflow workflow;
  final String startId;
}

const soloStartId = '__solo_start';

/// Builds the [SoloRun] for [nodeId] in [wf].
///
/// Each earlier step becomes a stand-in with the same name (so `$node["…"]`
/// expressions still work) that outputs [outputOf]'s items for it. The step
/// gets its exact last input on each of its input ports through feeder steps.
/// [portOutput] gives what an earlier step sent on one output port (null when
/// it hasn't run); [allOutput] gives all its items.
SoloRun soloRun(
  Workflow wf,
  String nodeId, {
  required List<JsonMap>? Function(String nodeId, int output) portOutput,
  required List<JsonMap>? Function(String nodeId) allOutput,
}) {
  final target = wf.node(nodeId);
  if (target == null) throw SoloRunException('step $nodeId is not in the workflow');
  final incoming = wf.connections.where((c) => c.to == nodeId).toList();
  if (incoming.isEmpty) {
    throw const SoloRunException('this step has no input: connect a step before it, or run the whole workflow');
  }

  // Everything upstream, nearest first.
  final ancestors = <String>[];
  final seen = <String>{nodeId};
  var frontier = [nodeId];
  while (frontier.isNotEmpty) {
    final next = <String>[];
    for (final id in frontier) {
      for (final c in wf.connections.where((c) => c.to == id)) {
        if (seen.add(c.from)) {
          ancestors.add(c.from);
          next.add(c.from);
        }
      }
    }
    frontier = next;
  }

  final start = WorkflowNode(id: soloStartId, name: '__solo start', type: 'trigger.manual');
  final nodes = <WorkflowNode>[start];
  final connections = <Connection>[];
  for (final id in ancestors) {
    final original = wf.node(id);
    if (original == null) continue;
    nodes.add(WorkflowNode(id: original.id, name: original.name, type: 'core.noop', pinned: allOutput(id) ?? const []));
    connections.add(Connection(from: soloStartId, to: original.id));
  }

  final ports = <int, List<Connection>>{};
  for (final c in incoming) {
    ports.putIfAbsent(c.input, () => []).add(c);
  }
  final missing = <String>{};
  for (final MapEntry(key: port, value: sources) in ports.entries) {
    final items = <JsonMap>[];
    var any = false;
    for (final c in sources) {
      final out = portOutput(c.from, c.output);
      if (out == null) {
        missing.add(wf.node(c.from)?.name ?? c.from);
        continue;
      }
      any = true;
      items.addAll(out);
    }
    if (!any) continue;
    final feeder = WorkflowNode(id: '__solo_in_$port', name: '__solo input $port', type: 'core.noop', pinned: items);
    nodes.add(feeder);
    connections
      ..add(Connection(from: soloStartId, to: feeder.id))
      ..add(Connection(from: feeder.id, to: nodeId, input: port));
  }
  if (connections.every((c) => c.to != nodeId)) {
    throw SoloRunException(
      'no data from ${missing.map((n) => '“$n”').join(' or ')} yet: run the workflow once '
      '(or pin test data on ${missing.length == 1 ? 'that step' : 'those steps'})',
    );
  }

  // The step itself always really runs, even if its output is pinned.
  nodes.add(WorkflowNode.fromJson({...target.toJson(), 'pinned': null}));
  return SoloRun(
    Workflow(id: wf.id, name: wf.name, nodes: nodes, connections: connections, variables: wf.variables),
    soloStartId,
  );
}
