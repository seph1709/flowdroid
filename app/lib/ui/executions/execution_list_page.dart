import 'package:material_ui/material_ui.dart';

import '../../core/execution_state.dart';
import '../../core/workflow.dart';
import '../../data/execution_record.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../widgets/format.dart';
import 'execution_detail_page.dart';
import '../icons.dart';

/// Past executions of one workflow, newest first.
class ExecutionListPage extends StatelessWidget {
  const ExecutionListPage({super.key, required this.workflow});

  final Workflow workflow;

  Future<void> _confirmClear(BuildContext context) async {
    final repository = ServicesScope.of(context).repository;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear run history?'),
        content: Text('All saved runs of "${workflow.name}" are deleted. The workflow itself is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed ?? false) await repository.clearExecutions(workflow.id);
  }

  @override
  Widget build(BuildContext context) {
    final repository = ServicesScope.of(context).repository;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Run history'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            icon: const Icon(AppIcons.sweep),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: repository,
        builder: (context, _) => FutureBuilder(
          future: repository.executions(workflow.id),
          builder: (context, snapshot) {
            final records = snapshot.data;
            if (records == null) return const Center(child: CircularProgressIndicator());
            if (records.isEmpty) return const _NoRuns();
            return ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) => _ExecutionTile(record: records[i]),
            );
          },
        ),
      ),
    );
  }
}

String _modeLabel(TriggerMode mode) => switch (mode) {
  TriggerMode.manual => 'Manual run',
  TriggerMode.schedule => 'Scheduled',
  TriggerMode.webhook => 'Webhook',
  TriggerMode.telegram => 'Telegram',
  TriggerMode.subworkflow => 'Called by a workflow',
  TriggerMode.error => 'Error workflow',
  TriggerMode.sms => 'SMS',
  TriggerMode.notification => 'Notification',
  TriggerMode.phone => 'Phone event',
  TriggerMode.place => 'Place',
  TriggerMode.share => 'Shared',
  TriggerMode.tile => 'Quick tile',
  TriggerMode.rss => 'RSS',
  TriggerMode.email => 'Email',
};

class _ExecutionTile extends StatelessWidget {
  const _ExecutionTile({required this.record});

  final ExecutionRecord record;

  @override
  Widget build(BuildContext context) {
    final ok = record.status == ExecutionStatus.success;
    return ListTile(
      leading: StatusRing(ok ? RunState.success : RunState.error),
      title: Text(
        '${_modeLabel(record.mode)} · ${formatRelative(record.startedAt)}',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      subtitle: Text(
        ok
            ? '${record.runs.length} steps · ${formatDuration(record.duration)} · ${formatTimestamp(record.startedAt)}'
            : readableError(record.error ?? 'Failed'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () =>
          Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ExecutionDetailPage(record: record))),
    );
  }
}

class _NoRuns extends StatelessWidget {
  const _NoRuns();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl * 1.5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconTile(icon: AppIcons.history, color: AppColors.of(context).textSecondary, size: 56),
            const SizedBox(height: Space.lg),
            Text('No runs yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: Space.sm),
            Text(
              'Tap Run in the editor, or activate the workflow and let its trigger fire. '
              'Every run appears here with each node\'s output.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
