import 'dart:convert';

import '../../assistant/assistant_chat.dart';
import '../../runtime/runner.dart';
import '../assistant/assistant_panel.dart';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/execution_state.dart';
import '../../core/json.dart';
import '../../core/workflow.dart';
import '../executions/execution_list_page.dart';
import '../kit/trigger_summary.dart';
import '../services_scope.dart';
import '../widgets/format.dart';
import '../widgets/json_view.dart';
import '../theme.dart';
import 'canvas_geometry.dart';
import 'editor_controller.dart';
import 'node_picker.dart';
import 'node_sheet.dart';
import 'workflow_canvas.dart';
import '../../runtime/linux/linux_runtime.dart';
import '../kit/activity_strip.dart';
import '../kit/kit.dart';
import '../icons.dart';

/// The workflow editor: canvas, add-node button, run button and workflow menu.
class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.workflow, this.openAssistant = false});

  final Workflow workflow;

  /// Opens the assistant once the editor is shown.
  final bool openAssistant;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final EditorController _controller;
  final _transformation = TransformationController();
  bool _ready = false;
  bool _fitted = false;
  Size _viewport = Size.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final services = ServicesScope.of(context);
    _controller = EditorController(services: services, workflow: widget.workflow)..validate();
    if (widget.openAssistant) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openAssistant();
      });
    }
    services.repository.latestExecution(widget.workflow.id).then((record) {
      if (mounted && record != null) setState(() => _controller.lastExecution = record);
    });
  }

  @override
  void dispose() {
    AssistantChat.of(_controller.workflow.id).detach();
    _controller.dispose();
    _transformation.dispose();
    super.dispose();
  }

  /// Zooms and pans so every node is visible in a [viewport]-sized area.
  void _fitToView(Size viewport) {
    final nodes = _controller.workflow.nodes;
    if (nodes.isEmpty || viewport.isEmpty) return;
    var bounds = Rect.fromLTWH(nodes.first.x, nodes.first.y, 0, 0);
    for (final n in nodes) {
      bounds = bounds.expandToInclude(
        Rect.fromLTWH(n.x, n.y, CanvasGeometry.nodeSize.width, CanvasGeometry.nodeSize.height),
      );
    }
    bounds = bounds.inflate(32);
    final scale = [
      viewport.width / bounds.width,
      viewport.height / bounds.height,
      1.0,
    ].reduce((a, b) => a < b ? a : b).clamp(0.3, 1.0);
    final dx = (viewport.width - bounds.width * scale) / 2 - bounds.left * scale;
    final dy = (viewport.height - bounds.height * scale) / 2 - bounds.top * scale;
    _transformation.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// Opens the assistant; the canvas follows its edits, then shows everything when it closes.
  Future<void> _openAssistant() async {
    await AssistantPanel.show(context, _controller, onCanvasChanged: _followAssistant);
    if (mounted) _fitToView(_viewport);
  }

  /// Fits the steps into the strip of canvas still visible above the assistant's panel.
  void _followAssistant() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final screen = MediaQuery.sizeOf(context).height;
      // The panel covers about 2/3 of the screen; the canvas ends above the bottom bar.
      const bottomBar = 90.0;
      final visible = _viewport.height - (screen * 0.66 - bottomBar);
      _fitToView(Size(_viewport.width, visible.clamp(120.0, _viewport.height)));
    });
  }

  /// Canvas point at the center of the visible area, where new nodes appear.
  Offset _visibleCenter() {
    final size = MediaQuery.sizeOf(context);
    final scene = _transformation.toScene(Offset(size.width / 2, size.height / 2.6));
    return scene - Offset(CanvasGeometry.nodeSize.width / 2, CanvasGeometry.nodeSize.height / 2);
  }

  /// [wanted], or the nearest spot below it that doesn't cover another step.
  Offset _freeSpot(Offset wanted) {
    const gap = 24.0;
    final size = CanvasGeometry.nodeSize;
    var at = wanted;
    for (var i = 0; i < 40; i++) {
      final rect = (at & size).inflate(gap);
      final hit = _controller.workflow.nodes.where((n) => rect.overlaps(Offset(n.x, n.y) & size)).toList();
      if (hit.isEmpty) return at;
      final lowest = hit.map((n) => n.y).reduce((a, b) => a > b ? a : b);
      at = Offset(at.dx, lowest + size.height + gap * 2);
    }
    return at;
  }

  Future<void> _addNode() async {
    final type = await NodePicker.show(context, _controller.services.catalog);
    if (type == null || !mounted) return;
    final from = _controller.connecting == null ? null : _controller.workflow.node(_controller.connecting!.nodeId);
    final at = _freeSpot(
      from == null ? _visibleCenter() : Offset(from.x, from.y + CanvasGeometry.nodeSize.height + 56),
    );
    _controller.addNode(type, x: at.dx, y: at.dy);
  }

  Future<void> _run() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_controller.triggers.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Add a trigger node first')));
      return;
    }
    final record = await _controller.run();
    if (record == null || !mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          record.succeeded
              ? 'Ran ${record.runs.length} nodes in ${formatDuration(record.duration)}'
              : record.error == stoppedByYou
              ? 'Stopped'
              : 'Run failed',
        ),
      ),
    );
  }

  Future<void> _nodeMenu(WorkflowNode node) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(AppIcons.tune),
              title: const Text('Open'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            if (!(_controller.typeOf(node)?.isTrigger ?? false))
              ListTile(
                leading: const Icon(AppIcons.play),
                title: const Text('Run this step'),
                subtitle: const Text('On the data from the last run'),
                onTap: () => Navigator.pop(context, 'runStep'),
              ),
            ListTile(
              leading: const Icon(AppIcons.copy),
              title: const Text('Duplicate'),
              onTap: () => Navigator.pop(context, 'duplicate'),
            ),
            ListTile(
              leading: Icon(node.disabled ? AppIcons.playCircle : AppIcons.pauseCircle),
              title: Text(node.disabled ? 'Enable' : 'Disable'),
              onTap: () => Navigator.pop(context, 'toggle'),
            ),
            ListTile(
              leading: const Icon(AppIcons.delete),
              title: const Text('Delete'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        await NodeSheet.show(context, _controller, node);
      case 'runStep':
        final error = await _controller.runStep(node);
        if (!mounted) return;
        if (error != null) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
        } else {
          await NodeSheet.show(context, _controller, node, openOutput: true);
        }
      case 'duplicate':
        _controller.duplicateNode(node);
      case 'toggle':
        _controller.setFlags(node, disabled: !node.disabled);
      case 'delete':
        _controller.deleteNode(node);
    }
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'executions':
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => ExecutionListPage(workflow: _controller.workflow)),
        );
      case 'curl':
        final request = await CurlImportSheet.show(context);
        final type = _controller.services.nodeType('http.request');
        if (request == null || type == null || !mounted) return;
        final at = _freeSpot(_visibleCenter());
        final node = _controller.addNode(type, x: at.dx, y: at.dy);
        _controller.setParams(node, request.toParams());
        await NodeSheet.show(context, _controller, node);
      case 'tidy':
        _controller.tidyUp();
        _fitToView(_viewport);
      case 'rename':
        final name = await _prompt('Rename workflow', _controller.workflow.name);
        if (name != null) _controller.rename(name);
      case 'variables':
        await _editVariables();
      case 'export':
        await Clipboard.setData(
          ClipboardData(text: const JsonEncoder.withIndent('  ').convert(_controller.workflow.toJson())),
        );
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Workflow JSON copied')));
      case 'issues':
        await _showIssues();
      case 'errorWorkflow':
        await _chooseErrorWorkflow();
      case 'shortcut':
        final ok = await _controller.services.phone.pinShortcut(_controller.workflow.id, _controller.workflow.name);
        if (mounted && !ok) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('This launcher does not support adding shortcuts')));
        }
    }
  }

  /// Picks the workflow that runs (from its Error Trigger) when this one fails.
  Future<void> _chooseErrorWorkflow() async {
    final services = _controller.services;
    final others = (await services.repository.workflows())
        .where((w) => w.id != _controller.workflow.id && w.nodesOfType('trigger.error').isNotEmpty)
        .toList();
    if (!mounted) return;
    final current = _controller.workflow.errorWorkflowId;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: Text(
                'When this workflow fails, run another one. It needs an Error Trigger.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            RadioGroup<String>(
              groupValue: current ?? '',
              onChanged: (v) => Navigator.pop(context, v),
              child: Column(
                children: [
                  const RadioListTile<String>(value: '', title: Text('None')),
                  for (final w in others) RadioListTile<String>(value: w.id, title: Text(w.name)),
                ],
              ),
            ),
            if (others.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.page),
                child: Text('No workflow has an Error Trigger yet. Create one first.'),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) _controller.setErrorWorkflow(chosen);
  }

  Future<String?> _prompt(String title, String initial, {bool multiline = false}) {
    final text = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLines: multiline ? 10 : 1,
          style: multiline ? const TextStyle(fontFamily: 'monospace') : null,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Save')),
        ],
      ),
    ).whenComplete(text.dispose);
  }

  Future<void> _editVariables() async {
    final current = const JsonEncoder.withIndent('  ').convert(_controller.workflow.variables);
    final edited = await _prompt(r'Variables ($vars, JSON object)', current, multiline: true);
    if (edited == null || !mounted) return;
    try {
      final decoded = jsonDecode(edited);
      if (decoded is! Map) throw const FormatException('Variables must be a JSON object');
      _controller.setVariables(asMap(decoded));
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Invalid JSON: ${e.message}')));
    }
  }

  Future<void> _showIssues() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Workflow check'),
      content: _controller.issues.isEmpty
          ? const Text('No problems found.')
          : SingleChildScrollView(child: JsonView(_controller.issues)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ),
  );

  void _openExecutions() => _menu('executions');

  /// "Every 15 min · ran 2 min ago", under the title.
  String _subtitle() {
    final trigger = _controller.triggers.firstOrNull;
    final p = trigger?.params ?? const <String, Object?>{};
    final what = triggerSummary(trigger?.type, p);
    final last = _controller.lastExecution;
    return last == null ? what : '$what · ran ${formatRelative(last.startedAt)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final wf = _controller.workflow;
        final issues = _controller.issues.length;
        final theme = Theme.of(context);
        final c = AppColors.of(context);
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, Space.xs, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        icon: Icon(AppIcons.back, color: c.text),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Assistant',
                        icon: Icon(AppIcons.sparkle, color: c.accent),
                        onPressed: _openAssistant,
                      ),
                      IconButton(
                        tooltip: 'Undo',
                        icon: const Icon(AppIcons.undo),
                        onPressed: _controller.canUndo ? _controller.undo : null,
                      ),
                      IconButton(
                        tooltip: 'Redo',
                        icon: const Icon(AppIcons.redo),
                        onPressed: _controller.canRedo ? _controller.redo : null,
                      ),
                      if (issues > 0)
                        IconButton(
                          tooltip: issues == 1 ? '1 problem' : '$issues problems',
                          icon: Badge(
                            label: Text('$issues'),
                            child: Icon(AppIcons.warning, color: c.warning),
                          ),
                          onPressed: _showIssues,
                        ),
                      PopupMenuButton<String>(
                        tooltip: 'More',
                        icon: const Icon(AppIcons.more),
                        onSelected: _menu,
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'curl', child: Text('Import cURL as a step')),
                          PopupMenuItem(value: 'tidy', child: Text('Tidy up')),
                          PopupMenuItem(value: 'rename', child: Text('Rename')),
                          PopupMenuItem(value: 'variables', child: Text('Variables')),
                          PopupMenuItem(value: 'errorWorkflow', child: Text('Error workflow')),
                          PopupMenuItem(value: 'shortcut', child: Text('Add to home screen')),
                          PopupMenuItem(value: 'export', child: Text('Copy as JSON')),
                          PopupMenuItem(value: 'issues', child: Text('Check workflow')),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.lg, Space.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              button: true,
                              hint: 'Rename',
                              child: GestureDetector(
                                onTap: () => _menu('rename'),
                                child: Text(
                                  wf.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.headlineMedium,
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.xs),
                            Text(
                              _subtitle(),
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Tooltip(
                          message: wf.active ? 'Active: runs on its trigger' : 'Inactive: runs only when you press Run',
                          child: Switch(value: wf.active, onChanged: _controller.setActive),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: c.hairline),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _viewport = constraints.biggest;
                      if (!_fitted) {
                        _fitted = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView(_viewport));
                      }
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: WorkflowCanvas(
                              controller: _controller,
                              transformation: _transformation,
                              onOpenNode: (node) => NodeSheet.show(context, _controller, node),
                              onNodeMenu: _nodeMenu,
                            ),
                          ),
                          Positioned(
                            left: Space.md,
                            right: Space.md,
                            top: Space.md,
                            child: Column(
                              children: [
                                _CanvasNotice(controller: _controller, onOpenExecutions: _openExecutions),
                                ValueListenableBuilder<LinuxActivity?>(
                                  valueListenable: _controller.services.linux.activity,
                                  builder: (context, activity, _) => activity == null
                                      ? const SizedBox.shrink()
                                      : Padding(
                                          padding: const EdgeInsets.only(top: Space.sm),
                                          child: ActivityStrip(activity: activity),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                _Toolbar(
                  running: _controller.running,
                  onAdd: _addNode,
                  onFit: () => _fitToView(_viewport),
                  onHistory: _openExecutions,
                  onRun: _run,
                  onStop: _controller.stop,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The editor's bottom bar: tools on the left, Run on the right, all inside the bar.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.running,
    required this.onAdd,
    required this.onFit,
    required this.onHistory,
    required this.onRun,
    required this.onStop,
  });

  final bool running;
  final VoidCallback onAdd;
  final VoidCallback onFit;
  final VoidCallback onHistory;
  final VoidCallback onRun;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.background,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.sm, Space.sm, Space.lg, Space.sm),
          child: Row(
            children: [
              IconButton(tooltip: 'Add step', icon: const Icon(AppIcons.addStep), onPressed: onAdd),
              IconButton(tooltip: 'Fit to screen', icon: const Icon(AppIcons.fit), onPressed: onFit),
              IconButton(tooltip: 'Run history', icon: const Icon(AppIcons.history), onPressed: onHistory),
              const Spacer(),
              // While it runs the button stops it; the spinner shows it is still going.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: running
                    ? FilledButton.icon(
                        key: const ValueKey('stop'),
                        onPressed: onStop,
                        icon: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: c.danger),
                        ),
                        label: const Text('Stop'),
                        style: FilledButton.styleFrom(backgroundColor: c.dangerSoft, foregroundColor: c.danger),
                      )
                    : FilledButton.icon(
                        key: const ValueKey('run'),
                        onPressed: onRun,
                        icon: const Icon(AppIcons.play, size: 20),
                        label: const Text('Run'),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A strip over the canvas: connect-mode instructions, or why the last run failed.
class _CanvasNotice extends StatelessWidget {
  const _CanvasNotice({required this.controller, required this.onOpenExecutions});

  final EditorController controller;
  final VoidCallback onOpenExecutions;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final last = controller.lastExecution;
    if (controller.connecting != null) {
      return _strip(
        context,
        background: c.text,
        foreground: c.background,
        icon: AppIcons.connect,
        text: 'Tap a step to connect it, or add a new one.',
        action: TextButton(
          onPressed: controller.cancelConnect,
          style: TextButton.styleFrom(foregroundColor: c.accentSoft),
          child: const Text('Cancel'),
        ),
      );
    }
    if (controller.running) {
      final active = controller.activeNodeId == null ? null : controller.workflow.node(controller.activeNodeId!);
      final done = controller.stepsDone;
      return _strip(
        context,
        background: c.surface,
        foreground: c.text,
        icon: AppIcons.play,
        text: [
          if (active != null) 'Waiting on ${active.name}' else 'Running',
          if (done > 0) done == 1 ? '1 step done' : '$done steps done',
        ].join(' · '),
        action: const Padding(padding: EdgeInsets.all(Space.md), child: QuietSpinner(size: 16)),
        bordered: true,
      );
    }
    if (last != null && !controller.running && last.error == stoppedByYou) {
      // A stop the person chose is not a failure.
      return _strip(
        context,
        background: c.grouped,
        foreground: c.textSecondary,
        icon: AppIcons.close,
        text: 'Stopped by you',
        bordered: true,
        action: TextButton(onPressed: onOpenExecutions, child: const Text('Details')),
      );
    }
    if (last != null && !controller.running && last.status != ExecutionStatus.success) {
      return _strip(
        context,
        background: c.dangerSoft,
        foreground: c.danger,
        icon: AppIcons.error,
        text: last.error ?? 'The last run failed.',
        action: TextButton(
          onPressed: onOpenExecutions,
          style: TextButton.styleFrom(foregroundColor: c.danger),
          child: const Text('Details'),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _strip(
    BuildContext context, {
    required Color background,
    required Color foreground,
    required IconData icon,
    required String text,
    required Widget action,
    bool bordered = false,
  }) {
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: bordered ? BorderSide(color: AppColors.of(context).hairline) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.xs, Space.xs),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
            action,
          ],
        ),
      ),
    );
  }
}
