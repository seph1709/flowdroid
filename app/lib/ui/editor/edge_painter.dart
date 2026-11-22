import 'dart:ui' show PointMode;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

import '../widgets/format.dart';
import 'canvas_geometry.dart';
import 'editor_controller.dart';

/// The board's texture: fine dots every 24 px. Static, so it never repaints while nodes move.
class GridPainter extends CustomPainter {
  const GridPainter({required this.minor});

  final Color minor;
  static const _step = 24.0;

  @override
  void paint(Canvas canvas, Size size) {
    final dots = <Offset>[
      for (var x = 0.0; x < size.width; x += _step)
        for (var y = 0.0; y < size.height; y += _step) Offset(x, y),
    ];
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = minor
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(GridPainter old) => old.minor != minor;
}

/// Draws connections as curves from output ports to input ports, labelled with item counts.
class EdgePainter extends CustomPainter {
  EdgePainter({required this.controller, required this.colors}) : super(repaint: controller);

  final EditorController controller;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final wf = controller.workflow;
    final lastRun = controller.lastExecution;
    for (final c in wf.connections) {
      final from = wf.node(c.from);
      final to = wf.node(c.to);
      if (from == null || to == null) continue;
      final start = CanvasGeometry.outputPort(from, c.output, controller.outputLabels(from).length);
      final end = CanvasGeometry.inputPort(to, c.input, controller.inputCount(to).clamp(1, 8));
      final carried = lastRun?.runOf(c.from)?.outputs.elementAtOrNull(c.output)?.length ?? 0;
      _paintEdge(canvas, start, end, highlighted: carried > 0, label: carried > 0 ? itemCount(carried) : null);
    }
  }

  void _paintEdge(Canvas canvas, Offset start, Offset end, {required bool highlighted, String? label}) {
    final bend = ((end.dy - start.dy).abs() / 2).clamp(28.0, 140.0);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(start.dx, start.dy + bend, end.dx, end.dy - bend, end.dx, end.dy);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighted ? 2 : 1.5
      ..strokeCap = StrokeCap.round
      ..color = highlighted ? colors.accent.withValues(alpha: 0.55) : colors.outline;
    canvas.drawPath(path, paint);
    if (label == null) return;
    final mid = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(fontFamily: AppTheme.monoFamily, fontSize: 11, color: colors.textSecondary),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Beside the line, not on it, so the connection stays visible.
    final box = Rect.fromCenter(
      center: mid + Offset(text.width / 2 + 14, 0),
      width: text.width + 12,
      height: text.height + 6,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(8)), Paint()..color = colors.canvas);
    text.paint(canvas, box.topLeft + const Offset(6, 3));
  }

  @override
  bool shouldRepaint(EdgePainter oldDelegate) => oldDelegate.colors != colors;
}
