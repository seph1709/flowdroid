import 'dart:ui';

import '../../core/workflow.dart';

/// Shared layout math, so node widgets and the edge painter agree on port positions.
/// Flow runs top to bottom: inputs sit on a step's top edge, outputs on its bottom edge.
abstract final class CanvasGeometry {
  static const nodeSize = Size(232, 64);

  /// Horizontal position of port [index] of [count], spread across the step's width.
  static double _portX(WorkflowNode node, int index, int count) => node.x + nodeSize.width * (index + 1) / (count + 1);

  static Offset inputPort(WorkflowNode node, int index, int count) => Offset(_portX(node, index, count), node.y);

  static Offset outputPort(WorkflowNode node, int index, int count) =>
      Offset(_portX(node, index, count), node.y + nodeSize.height);

  /// Port position relative to the step's top-left corner.
  static Offset local(Offset port, WorkflowNode node) => port - Offset(node.x, node.y);
}
