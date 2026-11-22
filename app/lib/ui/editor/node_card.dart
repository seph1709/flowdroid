import 'package:material_ui/material_ui.dart';

import '../../core/workflow.dart';
import '../kit/kit.dart';
import '../theme.dart';
import 'canvas_geometry.dart';
import 'editor_controller.dart';

/// One step on the canvas: a soft white tile with its icon, name, type and run status, plus its ports.
class NodeCard extends StatelessWidget {
  const NodeCard({super.key, required this.controller, required this.node, required this.onOpen, required this.onMenu});

  final EditorController controller;
  final WorkflowNode node;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  /// Space above and below the tile so port touch targets stay inside the card's bounds.
  static const inset = 22.0;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final type = controller.typeOf(node);
    final status = _runState(controller.statusOf(node));
    final outputs = controller.outputLabels(node);
    final inputs = controller.inputCount(node);
    final size = CanvasGeometry.nodeSize;
    final connectingHere = controller.connecting?.nodeId == node.id;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(type?.isTrigger ?? false ? 32 : 14),
      side: BorderSide(
        color: switch (status) {
          RunState.running => c.accent,
          RunState.error => c.danger.withValues(alpha: 0.5),
          _ => connectingHere ? c.accent : c.hairline,
        },
        width: status == RunState.running || connectingHere ? 1.5 : 1,
      ),
    );

    return SizedBox(
      width: size.width,
      height: size.height + inset * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: inset,
            width: size.width,
            height: size.height,
            child: GestureDetector(
              onPanUpdate: (d) => controller.moveNode(node, d.delta),
              child: Semantics(
                button: true,
                label:
                    '${node.name}, ${type?.label ?? node.type}, ${_statusWords(status)}${node.disabled ? ', disabled' : ''}',
                hint: 'Double tap to edit, long press for more',
                excludeSemantics: true,
                child: Opacity(
                  opacity: node.disabled ? 0.45 : 1,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(shape: shape, shadows: c.softShadow),
                    child: Material(
                      color: c.surface,
                      shape: shape,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () =>
                            controller.connecting != null && !connectingHere ? _connectHere(context) : onOpen(),
                        onLongPress: onMenu,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Space.md),
                          child: Row(
                            children: [
                              IconTile.forType(type: node.type, group: type?.group, size: 32),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      node.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      type?.label ?? 'Unknown step',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: Space.sm),
                              StatusRing(status, size: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (var i = 0; i < inputs; i++)
            _Port(
              center: _local(CanvasGeometry.inputPort(node, i, inputs)),
              active: false,
              onTap: controller.connecting == null ? null : () => _connectHere(context, i),
            ),
          if (outputs.length > 1)
            for (var i = 0; i < outputs.length; i++)
              Positioned(
                left: _local(CanvasGeometry.outputPort(node, i, outputs.length)).dx + 10,
                top: size.height + inset + 4,
                child: Text(outputs[i], style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 11)),
              ),
          for (var i = 0; i < outputs.length; i++)
            _Port(
              center: _local(CanvasGeometry.outputPort(node, i, outputs.length)),
              active: connectingHere && controller.connecting?.output == i,
              label: outputs.length > 1 ? outputs[i] : null,
              onTap: () => controller.beginConnect(node.id, i),
            ),
        ],
      ),
    );
  }

  static RunState _runState(NodeRunStatus s) => switch (s) {
    NodeRunStatus.idle => RunState.idle,
    NodeRunStatus.running => RunState.running,
    NodeRunStatus.success => RunState.success,
    NodeRunStatus.error => RunState.error,
  };

  static String _statusWords(RunState s) => switch (s) {
    RunState.idle => 'not run yet',
    RunState.running => 'running',
    RunState.success => 'last run succeeded',
    RunState.error => 'last run failed',
  };

  Offset _local(Offset port) => CanvasGeometry.local(port, node) + const Offset(0, inset);

  void _connectHere(BuildContext context, [int input = 0]) {
    if (!controller.completeConnect(node.id, input)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That step has no input to connect to')));
    }
  }
}

class _Port extends StatelessWidget {
  const _Port({required this.center, required this.active, this.onTap, this.label});

  final Offset center;
  final bool active;
  final VoidCallback? onTap;
  final String? label;

  /// Touch target around the dot, larger than the dot itself.
  static const _hit = 44.0;
  static const _dot = 12.0;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Positioned(
      left: center.dx - _hit / 2,
      top: center.dy - _hit / 2,
      width: _hit,
      height: _hit,
      child: Tooltip(
        message: label ?? '',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: active ? c.accent : c.surface,
                shape: BoxShape.circle,
                border: Border.all(color: active ? c.accent : c.outline, width: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
