import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:phone_bridge/phone_bridge.dart';

import '../core/execution_state.dart';
import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import 'services_scope.dart';
import 'widgets/format.dart';
import 'icons.dart';
import '../runtime/file_store.dart';
import '../runtime/share_items.dart';

/// Handles what FlowDroid was opened for: content shared from another app
/// (runs a workflow with a Share Trigger) or a home-screen shortcut (runs that workflow).
class LaunchHandler extends StatefulWidget {
  const LaunchHandler({super.key, required this.child});

  final Widget child;

  @override
  State<LaunchHandler> createState() => _LaunchHandlerState();
}

class _LaunchHandlerState extends State<LaunchHandler> {
  StreamSubscription<void>? _launches;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_launches != null) return;
    final phone = ServicesScope.of(context).phone;
    _launches = phone.launches.listen((_) => unawaited(_take()));
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_take()));
  }

  @override
  void dispose() {
    _launches?.cancel();
    super.dispose();
  }

  void _say(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _take() async {
    final Launch? launch;
    try {
      launch = await ServicesScope.of(context).phone.takeLaunch();
    } on Exception {
      return;
    }
    switch (launch) {
      case WorkflowShortcut(:final workflowId):
        await _runShortcut(workflowId);
      case SharedContent():
        await _runShare(launch);
      case null:
        break;
    }
  }

  Future<void> _runShortcut(String id) async {
    final services = ServicesScope.of(context);
    final wf = await services.repository.workflow(id);
    if (wf == null) return _say('That workflow was deleted');
    final trigger =
        wf.nodesOfType('trigger.manual').firstOrNull ??
        wf.nodes.where((n) => services.nodeType(n.type)?.isTrigger ?? false).firstOrNull;
    if (trigger == null) return _say('“${wf.name}” has no trigger');
    await _run(wf, trigger, TriggerMode.manual, const {});
  }

  Future<void> _runShare(SharedContent shared) async {
    final services = ServicesScope.of(context);
    final targets = [
      for (final wf in await services.repository.workflows())
        for (final t in wf.nodesOfType('trigger.share')) (wf, t),
    ];
    if (!mounted) return;
    if (targets.isEmpty) return _say('No workflow has a Share Trigger yet');
    final (Workflow, WorkflowNode)? target = targets.length == 1
        ? targets.single
        : await showModalBottomSheet<(Workflow, WorkflowNode)>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('Send to which workflow?')),
                  for (final t in targets)
                    ListTile(
                      leading: const Icon(AppIcons.share),
                      title: Text(t.$1.name),
                      onTap: () => Navigator.pop(context, t),
                    ),
                ],
              ),
            ),
          );
    if (target == null) return;
    final items = await shareItems(
      FileStore(services.dataDir),
      text: shared.text,
      subject: shared.subject,
      files: shared.files,
    );
    await _runItems(target.$1, target.$2, TriggerMode.share, items);
  }

  Future<void> _run(Workflow wf, WorkflowNode trigger, TriggerMode mode, JsonMap item) =>
      _runItems(wf, trigger, mode, [item]);

  Future<void> _runItems(Workflow wf, WorkflowNode trigger, TriggerMode mode, List<JsonMap> items) async {
    final runner = ServicesScope.of(context).runner;
    _say('Running “${wf.name}”…');
    final record = await runner.run(wf, triggerNodeId: trigger.id, mode: mode, items: items, usePinned: false);
    _say(
      record.status == ExecutionStatus.success
          ? '“${wf.name}” finished'
          : '“${wf.name}” failed: ${readableError(record.error ?? 'unknown error')}',
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
