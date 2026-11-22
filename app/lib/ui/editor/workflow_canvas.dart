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
    final dark = Theme.of(context).brightness == Brightness.dark;
    // A softly lit board: a cool wash with light falling from the top, fixed to the
    // screen, under a grid that moves with the nodes.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -1.1),
          radius: 1.5,
          colors: dark
              ? [const Color(0xFF1B1D24), c.canvas, const Color(0xFF0E0F12)]
              : [const Color(0xFFFFFFFF), const Color(0xFFF3F5F9), const Color(0xFFE9ECF2)],
          stops: const [0, 0.55, 1],
        ),
      ),
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
                    child: CustomPaint(
                      painter: GridPainter(
                        minor: (dark ? Colors.white : const Color(0xFF3B4A66)).withValues(alpha: dark ? 0.09 : 0.15),
                      ),
                    ),
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
