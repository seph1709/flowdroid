import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/execution_state.dart';
import '../../core/json.dart';
import '../../core/workflow.dart';
import '../../data/n8n_import.dart';
import '../../data/execution_record.dart';
import '../../data/templates.dart';
import '../editor/editor_page.dart';
import '../kit/kit.dart';
import '../kit/trigger_summary.dart';
import '../services_scope.dart';
import '../settings/settings_page.dart';
import '../theme.dart';
import '../widgets/format.dart';
import '../icons.dart';
import '../settings/background_setup_page.dart';

/// What "New workflow" should create.
sealed class _NewChoice {
  const _NewChoice();
}

class _Build extends _NewChoice {
  const _Build(this.build);

  final Workflow Function() build;
}

class _Import extends _NewChoice {
  const _Import();
}

/// A blank workflow, opened with the assistant ready to build it.
class _Assistant extends _NewChoice {
  const _Assistant();
}

/// The list of workflows: create, import, open and switch them on.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _open(BuildContext context, Workflow wf) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => EditorPage(workflow: wf)));

  Future<void> _create(BuildContext context) async {
    final choice = await showModalBottomSheet<_NewChoice>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _NewWorkflowSheet(),
    );
    if (choice == null || !context.mounted) return;
    final wf = switch (choice) {
      _Build(:final build) => build(),
      _Import() => await _importFromClipboard(context),
      _Assistant() => Workflow(id: newId('wf_'), name: 'New workflow'),
    };
    if (wf == null || !context.mounted) return;
    await ServicesScope.of(context).repository.saveWorkflow(wf);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(workflow: wf, openAssistant: choice is _Assistant),
      ),
    );
  }

  Future<Workflow?> _importFromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    try {
      final json = asMap(jsonDecode(data?.text ?? ''));
      if (json['nodes'] is! List) throw const FormatException('no "nodes" list');
      if (isN8nWorkflow(json)) {
        final imported = importN8n(json);
        if (imported.unsupported.isNotEmpty && context.mounted) {
          final kinds = imported.unsupported.map((t) => t.split('.').last).toSet().join(', ');
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Imported from n8n. Not supported yet, left as placeholders: $kinds')));
        }
        return imported.workflow;
      }
      // A fresh id, so importing twice never overwrites the first copy.
      return Workflow.fromJson({...json, 'id': newId('wf_'), 'active': false});
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Clipboard has no workflow: ${e.message}')));
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = ServicesScope.of(context).repository;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: repository,
          builder: (context, _) => FutureBuilder(
            future: repository.workflows(),
            builder: (context, snapshot) {
              final workflows = snapshot.data;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.sm, 0),
                      child: Row(
                        children: [
                          const Spacer(),
                          IconButton(
                            tooltip: 'Settings',
                            icon: const Icon(AppIcons.tune),
                            onPressed: () =>
                                Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Workflows', style: theme.textTheme.headlineMedium),
                          if (workflows != null && workflows.isNotEmpty) ...[
                            const SizedBox(height: Space.xs),
                            Text(_summary(workflows), style: theme.textTheme.bodySmall),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (workflows == null)
                    const SliverFillRemaining(child: Center(child: QuietSpinner()))
                  else if (workflows.isEmpty)
                    SliverFillRemaining(hasScrollBody: false, child: _EmptyState(onCreate: () => _create(context)))
                  else ...[
                    SliverToBoxAdapter(child: _BackgroundHint(workflows: workflows)),
                    SliverList.separated(
                      itemCount: workflows.length,
                      separatorBuilder: (_, _) =>
                          Divider(indent: Space.page + 40 + Space.md, color: AppColors.of(context).hairline),
                      itemBuilder: (context, i) =>
                          _WorkflowRow(workflow: workflows[i], onOpen: () => _open(context, workflows[i])),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                ],
              );
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New workflow',
        onPressed: () => _create(context),
        child: const Icon(AppIcons.add, size: 28),
      ),
    );
  }

  static String _summary(List<Workflow> workflows) {
    final active = workflows.where((w) => w.active).length;
    final total = workflows.length == 1 ? '1 workflow' : '${workflows.length} workflows';
    return active == 0 ? total : '$total · $active active';
  }
}

class _NewWorkflowSheet extends StatelessWidget {
  const _NewWorkflowSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(IconData icon, Color color, String title, String subtitle, _NewChoice choice) => InkWell(
      onTap: () => Navigator.pop(context, choice),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.page, vertical: Space.md),
        child: Row(
          children: [
            GlyphIcon(icon: icon, color: color, size: 32),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final c = AppColors.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: Text('New workflow', style: theme.textTheme.titleLarge),
            ),
            row(AppIcons.sparkle, c.accent, 'Describe it', 'The assistant builds it with you', const _Assistant()),
            row(AppIcons.add, c.accent, 'Blank', 'Starts with a manual trigger', const _Build(blankWorkflow)),
            row(AppIcons.pasteIn, c.text, 'Import', 'Paste a workflow copied as JSON', const _Import()),
            const SectionLabel('TEMPLATES'),
            for (final t in templates)
              row(NodeVisuals.icon(t.icon), _templateColor(context, t.icon), t.title, t.description, _Build(t.build)),
            const SizedBox(height: Space.lg),
          ],
        ),
      ),
    );
  }
}

Color _templateColor(BuildContext context, String type) {
  final group = ServicesScope.of(context).nodeType(type)?.group;
  final c = AppColors.of(context);
  return group == null ? c.accent : c.groupColor(group);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xxl, 0, Space.xxl, 120),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlyphIcon(icon: AppIcons.workflow, color: AppColors.of(context).accent, size: 64),
          const SizedBox(height: Space.lg),
          Text('Automate your phone', style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.sm),
          Text(
            'Connect a trigger to a few steps, press Run, and see every step’s result.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.xl),
          FilledButton(onPressed: onCreate, child: const Text('Create a workflow')),
        ],
      ),
    );
  }
}

class _WorkflowRow extends StatelessWidget {
  const _WorkflowRow({required this.workflow, required this.onOpen});

  final Workflow workflow;
  final VoidCallback onOpen;

  Future<void> _menu(BuildContext context) async {
    final repository = ServicesScope.of(context).repository;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: const Text('Duplicate'), onTap: () => Navigator.pop(context, 'duplicate')),
            ListTile(title: const Text('Copy as JSON'), onTap: () => Navigator.pop(context, 'export')),
            ListTile(
              title: Text('Delete', style: TextStyle(color: AppColors.of(context).danger)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'duplicate':
        await repository.saveWorkflow(
          Workflow.fromJson({
            ...workflow.toJson(),
            'id': newId('wf_'),
            'name': '${workflow.name} copy',
            'active': false,
          }),
        );
      case 'export':
        await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(workflow.toJson())));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Workflow JSON copied')));
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete “${workflow.name}”?'),
            content: const Text('The workflow and its run history are removed from this phone.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: AppColors.of(context).danger),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed ?? false) await repository.deleteWorkflow(workflow.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final theme = Theme.of(context);
    final trigger = workflow.nodes.where((n) => services.nodeType(n.type)?.isTrigger ?? false).firstOrNull;
    return InkWell(
      onTap: onOpen,
      onLongPress: () => _menu(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.md, Space.md),
        child: Row(
          children: [
            // Every row's icon is a trigger, so color would say nothing; it dims when the workflow is off.
            GlyphIcon(
              icon: NodeVisuals.icon(trigger?.type ?? ''),
              color: workflow.active ? AppColors.of(context).text : AppColors.of(context).textTertiary,
              size: 36,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(workflow.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  _LastRun(workflow: workflow, triggerLabel: triggerSummary(trigger?.type, trigger?.params)),
                ],
              ),
            ),
            Switch(
              value: workflow.active,
              onChanged: (active) => services.repository.saveWorkflow(workflow..active = active),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Every 15 min · ran 5 min ago" with a small status mark.
class _LastRun extends StatelessWidget {
  const _LastRun({required this.workflow, required this.triggerLabel});

  final Workflow workflow;
  final String triggerLabel;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final c = AppColors.of(context);
    return FutureBuilder<ExecutionRecord?>(
      future: ServicesScope.of(context).repository.latestExecution(workflow.id),
      builder: (context, snapshot) {
        final last = snapshot.data;
        if (last == null) return Text('$triggerLabel · never run', style: style, maxLines: 1);
        final ok = last.status == ExecutionStatus.success;
        return Row(
          children: [
            Flexible(
              child: Text(
                '$triggerLabel · ran ${formatRelative(last.startedAt)}',
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              ok ? AppIcons.checkCircle : AppIcons.error,
              size: 14,
              color: ok ? c.success : c.danger,
              semanticLabel: ok ? 'succeeded' : 'failed',
            ),
          ],
        );
      },
    );
  }
}

/// Warns that active schedules and webhooks stop with the app, until "Keep running" is on.
class _BackgroundHint extends StatelessWidget {
  const _BackgroundHint({required this.workflows});

  final List<Workflow> workflows;

  static const _automatic = {
    'trigger.schedule',
    'trigger.webhook',
    'trigger.mcp',
    'trigger.calendar',
    'trigger.telegram',
    'trigger.sms',
    'trigger.notification',
    'trigger.phone',
    'trigger.place',
    'trigger.rss',
    'trigger.email',
  };

  @override
  Widget build(BuildContext context) {
    final runtime = ServicesScope.runtimeOf(context);
    return ListenableBuilder(
      listenable: runtime,
      builder: (context, _) {
        final needsBackground = workflows.any((w) => w.active && w.nodes.any((n) => _automatic.contains(n.type)));
        if (!needsBackground) return const SizedBox.shrink();
        if (runtime.keepRunning) return const _PausedHint();
        final c = AppColors.of(context);
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
          child: Material(
            color: c.accentSoft,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
              child: Row(
                children: [
                  Icon(AppIcons.moon, color: c.accent, size: 20),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      'Schedules and webhooks pause when FlowDroid is closed.',
                      style: theme.textTheme.bodySmall?.copyWith(color: c.text),
                    ),
                  ),
                  TextButton(onPressed: () => runtime.setKeepRunning(true), child: const Text('Keep running')),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shown while "Keep running" is on but the phone paused FlowDroid anyway.
class _PausedHint extends StatelessWidget {
  const _PausedHint();

  Future<String?> _message(BuildContext context) async {
    final health = ServicesScope.of(context).health;
    if (await health.pausedNow()) return 'The phone has paused FlowDroid. Schedules and triggers are waiting.';
    final n = (await health.recentPauses()).length;
    if (n == 0) return null;
    return n == 1 ? 'The phone paused FlowDroid once today.' : 'The phone paused FlowDroid $n times today.';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _message(context),
    builder: (context, snapshot) {
      final text = snapshot.data;
      if (text == null) return const SizedBox.shrink();
      final c = AppColors.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
        child: Material(
          color: c.warningSoft,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.sm, Space.md),
            child: Row(
              children: [
                Icon(AppIcons.warning, color: c.warning, size: 20),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text)),
                ),
                TextButton(onPressed: () => BackgroundSetupPage.open(context), child: const Text('Fix')),
              ],
            ),
          ),
        ),
      );
    },
  );
}
