import 'dart:ui' show Size;

import 'workflow.dart';

/// The editable area of the canvas, in canvas units.
const canvasSize = Size(4000, 3000);

/// Vertical layered layout: each step sits one row below the deepest step that feeds it.
void layoutVertically(Workflow workflow, bool Function(WorkflowNode node) isTrigger) {
  const rowHeight = 112.0;
  const columnWidth = 264.0;
  const top = 40.0;
  final centerX = canvasSize.width / 2 - 116;
  final layer = <String, int>{};
  final queue = <String>[];
  for (final n in workflow.nodes.where(isTrigger)) {
    layer[n.id] = 0;
    queue.add(n.id);
  }
  // Longest-path layering, capped so cycles cannot loop forever.
  var guard = workflow.nodes.length * workflow.connections.length + workflow.nodes.length;
  while (queue.isNotEmpty && guard-- > 0) {
    final id = queue.removeAt(0);
    for (final c in workflow.connections.where((c) => c.from == id)) {
      final next = (layer[id] ?? 0) + 1;
      if ((layer[c.to] ?? -1) < next && next < workflow.nodes.length) {
        layer[c.to] = next;
        queue.add(c.to);
      }
    }
  }
  var orphanLayer = (layer.values.fold(0, (a, b) => a > b ? a : b)) + 1;
  for (final n in workflow.nodes) {
    layer.putIfAbsent(n.id, () => orphanLayer++);
  }
  final rows = <int, List<WorkflowNode>>{};
  for (final n in workflow.nodes) {
    rows.putIfAbsent(layer[n.id]!, () => []).add(n);
  }
  for (final MapEntry(key: row, value: nodes) in rows.entries) {
    final width = (nodes.length - 1) * columnWidth;
    for (final (i, n) in nodes.indexed) {
      n
        ..x = centerX - width / 2 + i * columnWidth
        ..y = top + row * rowHeight;
    }
  }
}
