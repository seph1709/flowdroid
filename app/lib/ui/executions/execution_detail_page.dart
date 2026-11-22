import 'package:material_ui/material_ui.dart';

import '../../data/execution_record.dart';
import '../kit/kit.dart';
import '../theme.dart';
import '../widgets/format.dart';
import '../widgets/file_cards.dart';
import '../widgets/json_view.dart';

/// Every node run of one execution, in order, with its output items.
class ExecutionDetailPage extends StatelessWidget {
  const ExecutionDetailPage({super.key, required this.record});

  final ExecutionRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(record.workflowName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${record.status.name.toUpperCase()}  ·  ${formatTimestamp(record.startedAt)}  ·  ${formatDuration(record.duration)}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (record.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: scheme.errorContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text(readableError(error))),
              ),
            ),
          const SizedBox(height: 12),
          for (final run in record.runs)
            Card(
              elevation: 0,
              color: AppColors.of(context).grouped,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                leading: StatusRing(run.error == null ? RunState.success : RunState.error),
                title: Text(run.name, style: Theme.of(context).textTheme.titleSmall),
                shape: const Border(),
                collapsedShape: const Border(),
                subtitle: Text(run.error == null ? itemCount(run.itemCount) : readableError(run.error!)),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  if (fileRefsIn(run.outputs.expand((items) => items)) case final files when files.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(bottom: 8), child: FileCards(files)),
                  for (final (i, items) in run.outputs.indexed) ...[
                    if (run.outputs.length > 1)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Text('Output ${i + 1}'),
                        ),
                      ),
                    JsonView(items, items: true, title: run.name),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
