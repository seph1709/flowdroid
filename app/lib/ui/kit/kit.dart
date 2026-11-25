/// Small shared building blocks of the app's design (see DESIGN.md).
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/node_catalog.dart';
import '../theme.dart';

/// Run state shown by a [StatusRing].
enum RunState { idle, running, success, error }

/// A 22 px ring: grey (idle), spinning arc (running), green dot (success), red cross (error).
class StatusRing extends StatelessWidget {
  const StatusRing(this.state, {super.key, this.size = 22});

  final RunState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final label = switch (state) {
      RunState.idle => 'not run yet',
      RunState.running => 'running',
      RunState.success => 'succeeded',
      RunState.error => 'failed',
    };
    final Widget ring = switch (state) {
      RunState.running => SizedBox.square(
        dimension: size,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
        ),
      ),
      _ => CustomPaint(size: Size.square(size), painter: _RingPainter(state, c)),
    };
    return Semantics(
      label: label,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        child: KeyedSubtree(key: ValueKey(state), child: ring),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.state, this.c);

  final RunState state;
  final AppColors c;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - 1.5;
    final color = switch (state) {
      RunState.success => c.success,
      RunState.error => c.danger,
      _ => c.outline,
    };
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    if (state == RunState.success) canvas.drawCircle(center, r * 0.45, Paint()..color = color);
    if (state == RunState.error) {
      final d = r * 0.42;
      final p = Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawLine(center + Offset(-d, -d), center + Offset(d, d), p);
      canvas.drawLine(center + Offset(d, -d), center + Offset(-d, d), p);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.state != state || old.c != c;
}

/// An icon on its own, with no tile behind it: a node's glyph in its group's
/// color, or any glyph in [color]. Colors come from the theme, so the icon
/// follows light and dark mode (and fades with it when the theme changes).
class GlyphIcon extends StatelessWidget {
  const GlyphIcon({super.key, required this.icon, this.color, this.size = 32}) : group = null;

  GlyphIcon.forType({super.key, required String type, required this.group, this.size = 32})
    : icon = NodeVisuals.icon(type),
      color = null;

  final IconData icon;

  /// The glyph's color; a node's group color when it has a group, else the text color.
  final Color? color;
  final NodeGroup? group;

  /// The square the glyph is laid out in; the glyph fills most of it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final group = this.group;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: Icon(icon, size: size * 0.72, color: color ?? (group == null ? c.text : c.groupColor(group))),
      ),
    );
  }
}

/// A small label on a soft tint of [color], such as a workflow's trigger kind.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(Radii.tag),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An icon on a small square of its own color's tint: how steps and workflows are marked.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color, this.size = 32});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(icon, size: size * 0.56, color: color),
    );
  }
}

/// A small heading above a group of rows or fields.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(Space.page, Space.xl, Space.page, Space.sm),
  });

  final String text;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(text, style: Theme.of(context).textTheme.labelSmall),
  );
}

/// Rows on a rounded grouped background, separated by inset hairlines.
class GroupedSection extends StatelessWidget {
  const GroupedSection({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(horizontal: Space.lg),
  });

  final List<Widget> children;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: c.card(),
        // The card's white is a Material, so row taps show their ripple on it.
        child: Material(
          color: c.surface,
          borderRadius: BorderRadius.circular(Radii.card - 1),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) Divider(indent: Space.lg, height: 1, color: c.hairline),
                child,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A label above a form field.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key, this.hint});

  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text.rich(
        TextSpan(
          text: text,
          children: [
            if (hint != null)
              TextSpan(
                text: '  $hint',
                style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).textTertiary),
              ),
          ],
        ),
        style: theme.textTheme.labelMedium,
      ),
    );
  }
}

/// A rotating arc used while something loads; quieter than a full spinner.
class QuietSpinner extends StatefulWidget {
  const QuietSpinner({super.key, this.size = 20});

  final double size;

  @override
  State<QuietSpinner> createState() => _QuietSpinnerState();
}

class _QuietSpinnerState extends State<QuietSpinner> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.of(context).textTertiary;
    return RotationTransition(
      turns: _controller,
      child: CustomPaint(size: Size.square(widget.size), painter: _ArcPainter(color)),
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawArc(
      Offset.zero & size,
      0,
      math.pi * 1.4,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

/// A borderless switch between a few choices: a soft track with a raised thumb
/// that slides to the selected one.
class PillSwitch<T> extends StatelessWidget {
  const PillSwitch({super.key, required this.value, required this.options, required this.onChanged});

  final T value;
  final List<({T value, String label, IconData? icon})> options;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final index = options.indexWhere((o) => o.value == value).clamp(0, options.length - 1);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      // Darker than the grey page in light mode, so the track still reads as one.
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? c.grouped : c.hairline,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / options.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Raised above the track: white in light mode, a lighter grey in dark.
                    color: Theme.of(context).brightness == Brightness.dark ? c.outline : c.surface,
                    borderRadius: BorderRadius.circular(Radii.control - 3),
                    boxShadow: [
                      BoxShadow(color: c.shadow, blurRadius: 1, offset: const Offset(0, 1)),
                      BoxShadow(color: c.shadow, blurRadius: 8, offset: const Offset(0, 2)),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: Row(
                  children: [
                    for (final (i, o) in options.indexed)
                      Expanded(
                        child: Semantics(
                          selected: i == index,
                          button: true,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: onChanged == null ? null : () => onChanged!(o.value),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (o.icon != null) ...[
                                  Icon(o.icon, size: 17, color: i == index ? c.text : c.textTertiary),
                                  const SizedBox(width: 6),
                                ],
                                AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 160),
                                  style: theme.textTheme.labelLarge!.copyWith(
                                    fontSize: 14,
                                    color: i == index ? c.text : c.textSecondary,
                                    fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                                  ),
                                  child: Text(o.label),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
