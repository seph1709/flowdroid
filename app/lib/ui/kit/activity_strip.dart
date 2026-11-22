import 'package:material_ui/material_ui.dart';

import '../../runtime/linux/linux_runtime.dart';
import '../icons.dart';
import '../theme.dart';

/// A quiet card for a long background job: title, step, percent and a thin bar.
class ActivityStrip extends StatelessWidget {
  const ActivityStrip({super.key, required this.activity});

  final LinuxActivity activity;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final pct = activity.percent;
    return Semantics(
      liveRegion: true,
      label: '${activity.title}, ${activity.step}${pct == null ? '' : ', $pct percent'}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.hairline),
          boxShadow: c.softShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.server, size: 16, color: c.accent),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    '${activity.title} · ${activity.step}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: c.text),
                  ),
                ),
                if (pct != null)
                  Text(
                    '$pct%',
                    style: theme.textTheme.labelMedium?.copyWith(color: c.accent, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
            if (activity.detail case final detail?) ...[
              const SizedBox(height: 2),
              Text(detail, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12)),
            ],
            const SizedBox(height: Space.sm),
            ProgressBar(value: activity.fraction),
          ],
        ),
      ),
    );
  }
}

/// A 4 px rounded bar that eases between values; indeterminate when [value] is null.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, this.height = 4});

  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final v = value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: v == null
          ? LinearProgressIndicator(minHeight: height, backgroundColor: c.hairline, color: c.accent)
          : TweenAnimationBuilder<double>(
              tween: Tween(end: v.clamp(0, 1)),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              builder: (_, x, _) =>
                  LinearProgressIndicator(value: x, minHeight: height, backgroundColor: c.hairline, color: c.accent),
            ),
    );
  }
}
