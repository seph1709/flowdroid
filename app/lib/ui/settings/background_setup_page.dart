import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phone_bridge/phone_bridge.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/json.dart';
import '../../runtime/background_health.dart';
import '../../runtime/oem_guide_source.dart';
import '../../runtime/oem_guides.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../widgets/format.dart';

/// Everything that decides whether workflows run while FlowDroid is closed:
/// Android's settings, the phone maker's own battery manager, and a live
/// record of when the phone paused FlowDroid anyway.
class BackgroundSetupPage extends StatefulWidget {
  const BackgroundSetupPage({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BackgroundSetupPage()));

  @override
  State<BackgroundSetupPage> createState() => _BackgroundSetupPageState();
}

class _BackgroundSetupPageState extends State<BackgroundSetupPage> with WidgetsBindingObserver {
  BackgroundStatus? _status;
  DateTime? _lastBeat;
  bool _pausedNow = false;
  List<Pause> _pauses = const [];
  Set<String> _done = {};
  bool _busy = false;
  LiveGuide? _live;
  bool _liveLoading = false;
  String? _liveFor;

  Future<void> _loadGuide(String maker, {bool refresh = false}) async {
    setState(() => _liveLoading = true);
    final guide = await OemGuideSource(ServicesScope.of(context).dataDir).load(maker, refresh: refresh);
    if (!mounted) return;
    setState(() {
      _live = guide;
      _liveLoading = false;
    });
  }

  File get _doneFile => File('${ServicesScope.of(context).dataDir.path}/runtime/setup_done.json');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-reads everything when the user comes back from a system settings screen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final services = ServicesScope.of(context);
    final status = await services.phone.backgroundStatus();
    final last = await services.health.lastBeat();
    final paused = await services.health.pausedNow();
    final pauses = await services.health.recentPauses();
    Set<String> done = {};
    try {
      done = asList(jsonDecode(await _doneFile.readAsString())).whereType<String>().toSet();
    } on Object {
      // Nothing marked yet.
    }
    if (!mounted) return;
    setState(() {
      _status = status;
      _lastBeat = last;
      _pausedNow = paused;
      _pauses = pauses;
      _done = done;
    });
    if (_liveFor != status.maker) {
      _liveFor = status.maker;
      await _loadGuide(status.maker);
    }
  }

  Future<void> _toggleDone(String key) async {
    final next = {..._done};
    if (!next.remove(key)) next.add(key);
    setState(() => _done = next);
    await _doneFile.parent.create(recursive: true);
    await _doneFile.writeAsString(jsonEncode(next.toList()));
  }

  Future<void> _open(String kind) async {
    final ok = await ServicesScope.of(context).phone.openBackgroundSettings(kind);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This phone has no such screen. Look for it in Settings → Apps → FlowDroid.')),
      );
    }
  }

  Future<void> _setKeepRunning(bool enabled) async {
    setState(() => _busy = true);
    if (enabled && await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!mounted) return;
    final ok = await ServicesScope.runtimeOf(context).setKeepRunning(enabled);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Android did not allow the background service')));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final runtime = ServicesScope.runtimeOf(context);
    final s = _status;
    return Scaffold(
      appBar: AppBar(),
      body: ListenableBuilder(
        listenable: runtime,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: Space.xxl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
                child: Text('Background setup', style: theme.textTheme.headlineMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
                child: Text(
                  'What lets your workflows run while FlowDroid is closed and the screen is off.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              _HealthCard(
                keepRunning: runtime.keepRunning,
                lastBeat: _lastBeat,
                pausedNow: _pausedNow,
                pauses: _pauses,
              ),
              if (s == null)
                const Padding(
                  padding: EdgeInsets.all(Space.xxl),
                  child: Center(child: QuietSpinner()),
                )
              else ...[
                const SectionLabel('ANDROID'),
                GroupedSection(
                  children: [
                    _CheckRow(
                      ok: runtime.keepRunning,
                      title: 'Keep running',
                      subtitle: runtime.keepRunning
                          ? 'The background service is on'
                          : 'Off: workflows run only while FlowDroid is open',
                      trailing: Switch(value: runtime.keepRunning, onChanged: _busy ? null : _setKeepRunning),
                    ),
                    _CheckRow(
                      ok: s.notifications,
                      title: 'Notifications',
                      subtitle: s.notifications
                          ? 'Allowed. Keep the “Background runtime” notice on: it keeps the service alive'
                          : 'Blocked: some phones stop a service whose notice is hidden',
                      action: s.notifications ? null : ('Allow', () => _open('notifications')),
                    ),
                    _CheckRow(
                      ok: s.batteryUnrestricted,
                      title: 'Battery',
                      subtitle: s.batteryUnrestricted
                          ? 'Unrestricted'
                          : 'Optimized: Android pauses FlowDroid when idle',
                      action: s.batteryUnrestricted ? null : ('Allow', () => _open('battery')),
                    ),
                    if (s.backgroundRestricted)
                      _CheckRow(
                        ok: false,
                        title: 'Background activity',
                        subtitle: 'Restricted for FlowDroid in its app settings',
                        action: ('Open', () => _open('app')),
                      ),
                    _CheckRow(
                      ok: s.overlay,
                      optional: true,
                      title: 'Open links from the background',
                      subtitle: s.overlay ? 'Allowed: Open URL works while FlowDroid is closed' : 'Optional. Without it, Open URL shows a “Tap to open” notification when FlowDroid is closed',
                      action: s.overlay ? null : ('Allow', () => _open('overlay')),
                    ),
                    if (s.sdk >= 31)
                      _CheckRow(
                        ok: s.exactAlarms,
                        title: 'Alarms and reminders',
                        subtitle: s.exactAlarms
                            ? 'Allowed: schedules wake FlowDroid on time'
                            : 'Not allowed: schedules may run a few minutes late',
                        action: s.exactAlarms ? null : ('Allow', () => _open('exactAlarms')),
                      ),
                  ],
                ),
                ..._makerSection(context, s),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.page, Space.xl, Space.page, 0),
                  child: Text.rich(
                    TextSpan(
                      text: 'Another phone, or still paused? ',
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: GestureDetector(
                            onTap: () => launchUrl(
                              Uri.parse('https://dontkillmyapp.com/${guideFor(s.maker).isStock ? '' : s.maker}'),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: Text(
                              'dontkillmyapp.com',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.of(context).accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const TextSpan(text: ' has steps for every phone and system version.'),
                      ],
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _makerSection(BuildContext context, BackgroundStatus s) {
    final builtIn = guideFor(s.maker);
    final live = _live;
    final theme = Theme.of(context);
    final brand = s.brand.isEmpty ? 'This phone' : '${s.brand[0].toUpperCase()}${s.brand.substring(1)}';
    if (live == null && _liveLoading) {
      return const [
        Padding(
          padding: EdgeInsets.all(Space.xl),
          child: Center(child: QuietSpinner()),
        ),
      ];
    }
    if (live == null && builtIn.isStock) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.page, Space.lg, Space.page, 0),
          child: Text('$brand needs only the Android settings above.', style: theme.textTheme.bodySmall),
        ),
      ];
    }
    final name = live?.name.isNotEmpty == true ? live!.name : builtIn.name;
    const launchKey = 'autostart';
    const recentsKey = 'recents';
    return [
      SectionLabel('ON YOUR ${name.toUpperCase()}'),
      GroupedSection(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (live != null) ...[_Severity(name: name, level: live.severity), const SizedBox(height: Space.sm)],
                Text(
                  '$name phones can stop apps even when Android’s battery setting is Unrestricted. '
                  'Android can’t tell FlowDroid how these settings are set, so mark them when they’re done.',
                  style: theme.textTheme.bodySmall,
                ),
                // Without the live guide (offline, never loaded), the short built-in steps.
                if (live == null) ...[
                  const SizedBox(height: Space.md),
                  for (final (i, step) in builtIn.steps.indexed) _NumberedStep(number: i + 1, text: step),
                ],
                const SizedBox(height: Space.md),
                // Wraps onto two lines on narrow phones instead of the two buttons touching.
                Wrap(
                  spacing: Space.md,
                  runSpacing: Space.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (s.hasAutostartScreen)
                      FilledButton.icon(
                        onPressed: () => _open('autostart'),
                        icon: const Icon(AppIcons.external, size: 18),
                        label: Text(builtIn.autostartLabel ?? 'Open app launch settings'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => _open('app'),
                        icon: const Icon(AppIcons.external, size: 18),
                        label: const Text('Open FlowDroid’s app settings'),
                      ),
                    _DoneToggle(done: _done.contains(launchKey), onTap: () => _toggleDone(launchKey)),
                  ],
                ),
              ],
            ),
          ),
          if (live != null)
            for (final (i, section) in live.sections.indexed)
              _GuideSectionTile(section: section, initiallyExpanded: i == 0),
          if (live == null || builtIn.lockInRecents)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Lock in recent apps', style: theme.textTheme.bodyLarge),
                        Text(
                          'Open recent apps and swipe down on FlowDroid (or tap its lock), so “clear all” skips it.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  _DoneToggle(done: _done.contains(recentsKey), onTap: () => _toggleDone(recentsKey)),
                ],
              ),
            ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.page, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                live == null
                    ? 'Offline: showing FlowDroid’s short version.'
                    : 'Steps from dontkillmyapp.com, kept up to date by its community · '
                          'checked ${formatRelative(live.fetchedAt)}',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: () => _loadGuide(s.maker, refresh: true), child: const Text('Refresh')),
          ],
        ),
      ),
    ];
  }
}

class _NumberedStep extends StatelessWidget {
  const _NumberedStep({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.outline),
            ),
            child: Text('$number', style: theme.textTheme.labelSmall?.copyWith(color: c.text)),
          ),
          const SizedBox(width: Space.md),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// "How hard Huawei stops background apps": five dots.
class _Severity extends StatelessWidget {
  const _Severity({required this.name, required this.level});

  final String name;
  final int level;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final color = level >= 4 ? c.danger : (level >= 2 ? c.warning : c.success);
    return Semantics(
      label: '$name stops background apps: $level of 5',
      excludeSemantics: true,
      child: Row(
        children: [
          for (var i = 0; i < 5; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(shape: BoxShape.circle, color: i < level ? color : c.hairline),
            ),
          const SizedBox(width: Space.sm),
          Text(switch (level) {
            >= 4 => 'Stops background apps very often',
            >= 2 => 'Sometimes stops background apps',
            _ => 'Rarely stops background apps',
          }, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// One part of the live guide, folded until tapped.
class _GuideSectionTile extends StatelessWidget {
  const _GuideSectionTile({required this.section, required this.initiallyExpanded});

  final GuideSection section;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      title: Text(section.title.isEmpty ? 'Overview' : section.title, style: theme.textTheme.bodyLarge),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.textSecondary,
      collapsedIconColor: c.textTertiary,
      childrenPadding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in section.blocks)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: switch (block) {
              GuideText(:final text, code: true) => Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Space.sm),
                decoration: BoxDecoration(color: c.background, borderRadius: BorderRadius.circular(8)),
                child: SelectableText(text, style: AppTheme.monospace.copyWith(fontSize: 12, color: c.text)),
              ),
              GuideText(:final text, bullet: true) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, right: Space.sm),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                    ),
                  ),
                  Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
                ],
              ),
              GuideText(:final text) => Text(text, style: theme.textTheme.bodySmall?.copyWith(color: c.text)),
              GuidePictures(:final pictures) => SizedBox(
                height: 236,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in pictures)
                      Container(
                        width: 130,
                        margin: const EdgeInsets.only(right: Space.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                p.url,
                                height: 170,
                                width: 130,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => Container(height: 170, color: c.hairline),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              p.caption,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            },
          ),
      ],
    );
  }
}

/// Whether the service has been running, and when the phone paused it.
class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.keepRunning, required this.lastBeat, required this.pausedNow, required this.pauses});

  final bool keepRunning;
  final DateTime? lastBeat;
  final bool pausedNow;
  final List<Pause> pauses;

  static String _time(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  static String _length(Duration d) =>
      d.inMinutes < 60 ? '${d.inMinutes} min' : '${d.inHours} h ${d.inMinutes % 60} min';

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final (Color fg, Color bg, IconData icon, String title, String detail) = switch (()) {
      _ when !keepRunning => (
        c.textSecondary,
        c.grouped,
        AppIcons.moon,
        'Not running in the background',
        'Turn on Keep running below.',
      ),
      _ when pausedNow => (
        c.danger,
        c.dangerSoft,
        AppIcons.pauseCircle,
        'Paused by the phone',
        'No background check since ${lastBeat == null ? 'a while' : formatRelative(lastBeat!)}. '
            'Work through the steps below.',
      ),
      _ when pauses.isNotEmpty => (
        c.warning,
        c.warningSoft,
        AppIcons.warning,
        pauses.length == 1 ? 'Paused once in the last day' : 'Paused ${pauses.length} times in the last day',
        'Longest ${_length(pauses.map((p) => p.length).reduce((a, b) => a > b ? a : b))}. '
            'Something below still lets the phone stop FlowDroid.',
      ),
      _ => (
        c.success,
        c.successSoft,
        AppIcons.checkCircle,
        'Running in the background',
        lastBeat == null ? 'Starting…' : 'Last check ${formatRelative(lastBeat!)} · no pauses in the last day',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      child: Container(
        padding: const EdgeInsets.all(Space.lg),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                ),
              ],
            ),
            const SizedBox(height: Space.xs),
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: c.text)),
            ),
            if (keepRunning && pauses.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              for (final p in pauses.take(4))
                Padding(
                  padding: const EdgeInsets.only(left: 32, top: 2),
                  child: Text(
                    '${_time(p.from)} – ${_time(p.to)}  ·  ${_length(p.length)}',
                    style: AppTheme.monospace.copyWith(fontSize: 12, color: c.textSecondary),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.ok,
    required this.title,
    required this.subtitle,
    this.action,
    this.trailing,
    this.optional = false,
  });

  final bool ok;

  /// Not needed for background runs: shown without a warning when off.
  final bool optional;
  final String title;
  final String subtitle;
  final (String, VoidCallback)? action;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
      child: Row(
        children: [
          Icon(
            ok ? AppIcons.checkCircle : (optional ? AppIcons.external : AppIcons.warning),
            size: 20,
            color: ok ? c.success : (optional ? c.textTertiary : c.warning),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          if (trailing != null)
            trailing!
          else if (action case (final label, final onTap))
            TextButton(onPressed: onTap, child: Text(label)),
        ],
      ),
    );
  }
}

/// "Done" for a step the app can't check by itself.
class _DoneToggle extends StatelessWidget {
  const _DoneToggle({required this.done, required this.onTap});

  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      checked: done,
      button: true,
      label: 'Done',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 8),
          decoration: BoxDecoration(
            color: done ? c.successSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: done ? Colors.transparent : c.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(done ? AppIcons.check : AppIcons.add, size: 16, color: done ? c.success : c.textSecondary),
              const SizedBox(width: 6),
              Text(
                done ? 'Done' : 'Mark done',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: done ? c.success : c.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
