import 'package:material_ui/material_ui.dart';

import '../../core/workflow.dart';
import '../theme.dart';
import 'edge_painter.dart';
import 'editor_controller.dart';
import 'node_card.dart';

/// The pannable, zoomable board with every node and connection.
class WorkflowCanvas extends StatelessWidget {
  const WorkflowCanvas({
    super.key,
    required this.controller,
    required this.transformation,
    required this.onOpenNode,
    required this.onNodeMenu,
  });

  final EditorController controller;
  final TransformationController transformation;
  final void Function(WorkflowNode node) onOpenNode;
  final void Function(WorkflowNode node) onNodeMenu;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    // A flat grey board, the same grey as the page, under a dot grid that moves with the nodes.
    return DecoratedBox(
      decoration: BoxDecoration(color: c.canvas),
      child: InteractiveViewer(
        transformationController: transformation,
        constrained: false,
        minScale: 0.3,
        maxScale: 2,
        boundaryMargin: const EdgeInsets.all(200),
        child: SizedBox.fromSize(
          size: canvasSize,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (controller.connecting != null) controller.cancelConnect();
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: GridPainter(minor: c.textTertiary.withValues(alpha: 0.35))),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: EdgePainter(controller: controller, colors: AppColors.of(context)),
                  ),
                ),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => Stack(
                    children: [
                      for (final node in controller.workflow.nodes)
                        Positioned(
                          key: ValueKey(node.id),
                          left: node.x,
                          top: node.y - NodeCard.inset,
                          child: NodeCard(
                            controller: controller,
                            node: node,
                            onOpen: () => onOpenNode(node),
                            onMenu: () => onNodeMenu(node),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
