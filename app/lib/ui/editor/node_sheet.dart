import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/curl.dart';
import '../../core/json.dart';

import '../../core/node_catalog.dart';
import '../../core/workflow.dart';
import '../kit/kit.dart';
import '../theme.dart';
import '../widgets/format.dart';
import '../widgets/file_cards.dart';
import '../widgets/json_view.dart';
import 'editor_controller.dart';
import 'data_mapping.dart';
import 'param_assists.dart';
import 'param_editors.dart';
import '../widgets/syntax.dart';
import '../icons.dart';

/// Bottom sheet for one node: the data coming in, parameters and settings, and last output.
class NodeSheet extends StatefulWidget {
  const NodeSheet({super.key, required this.controller, required this.node, this.openOutput = false});

  final EditorController controller;
  final WorkflowNode node;

  /// Start on the Output tab.
  final bool openOutput;

  static Future<void> show(
    BuildContext context,
    EditorController controller,
    WorkflowNode node, {
    bool openOutput = false,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => NodeSheet(controller: controller, node: node, openOutput: openOutput),
  );

  @override
  State<NodeSheet> createState() => _NodeSheetState();
}

class _NodeSheetState extends State<NodeSheet> with SingleTickerProviderStateMixin {
  late final bool _hasInput = !(widget.controller.typeOf(widget.node)?.isTrigger ?? false);
  late final _tabs = TabController(
    length: _hasInput ? 3 : 2,
    initialIndex: widget.openOutput ? (_hasInput ? 2 : 1) : (_hasInput ? 1 : 0),
    vsync: this,
  );
  late final _mapping = MappingController(MappingController.sourcesFor(widget.controller, widget.node))
    ..onInserted = () => _tabs.animateTo(_hasInput ? 1 : 0);

  final _inputScroll = ScrollController();

  /// Runs only this step on its last input, then shows the result.
  Future<void> _runStep() async {
    final error = await widget.controller.runStep(widget.node);
    if (!mounted) return;
    _tabs.animateTo(_tabs.length - 1);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  void dispose() {
    _tabs.dispose();
    _mapping.dispose();
    _inputScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final node = widget.node;
    return MappingScope(
      mapping: _mapping,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        maxChildSize: 0.95,
        builder: (context, scroll) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            children: [
              _Header(controller: controller, node: node, onRunStep: _runStep),
              TabBar(
                controller: _tabs,
                tabs: [
                  if (_hasInput) const Tab(text: 'Input'),
                  const Tab(text: 'Parameters'),
                  const Tab(text: 'Output'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    if (_hasInput) InputPanel(mapping: _mapping, scroll: _inputScroll),
                    // Kept alive so a field picked from Input still exists to receive the value.
                    _KeepAlive(
                      child: _ParametersTab(controller: controller, node: node, scroll: scroll),
                    ),
                    _OutputTab(controller: controller, node: node),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Node icon, editable name and type, then what the node does.
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.node, required this.onRunStep});

  final EditorController controller;
  final WorkflowNode node;
  final Future<void> Function() onRunStep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = controller.typeOf(node);
    final accent = type == null ? theme.colorScheme.error : NodeVisuals.color(type.group);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xl, 0, Space.lg, Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: NodeVisuals.icon(node.type), color: accent, size: 44),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _NameField(controller: controller, node: node),
                    Text(
                      type?.label ?? 'Unknown node type',
                      style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(
            type?.description ?? 'This node type is not supported by this app version.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => _Chip(
                  icon: AppIcons.play,
                  label: controller.running && controller.activeNodeId == node.id
                      ? 'Running…'
                      : (type?.isTrigger ?? false ? 'Run workflow' : 'Run this step'),
                  accent: true,
                  onTap: controller.running ? () {} : onRunStep,
                ),
              ),
              if (node.type == 'http.request') ...[
                _Chip(
                  icon: AppIcons.curl,
                  label: 'Import cURL',
                  onTap: () => importCurlInto(context, controller, node),
                ),
                _Chip(
                  icon: AppIcons.copy,
                  label: 'Copy as cURL',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: toCurl(node.params)));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('cURL command copied')));
                    }
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Renames on submit or when focus leaves, so a half-typed name never collides.
class _NameField extends StatefulWidget {
  const _NameField({required this.controller, required this.node});

  final EditorController controller;
  final WorkflowNode node;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _text = TextEditingController(text: widget.node.name);

  void _commit() {
    widget.controller.renameNode(widget.node, _text.text);
    _text.text = widget.node.name;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) {
        if (!focused) _commit();
      },
      child: TextField(
        controller: _text,
        style: Theme.of(context).textTheme.titleLarge,
        decoration: const InputDecoration(
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          hintText: 'Node name',
          suffixIcon: Icon(AppIcons.edit, size: 18),
          suffixIconConstraints: BoxConstraints(minWidth: 32, minHeight: 32),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

class _ParametersTab extends StatelessWidget {
  const _ParametersTab({required this.controller, required this.node, required this.scroll});

  final EditorController controller;
  final WorkflowNode node;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final type = controller.typeOf(node);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final outgoing = controller.workflow.connections.where((c) => c.from == node.id).toList();
        final labels = controller.outputLabels(node);
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.all(16),
          children: [
            for (final spec in (type?.params ?? const <ParamSpec>[]).where((p) => paramVisible(node, p)))
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ParamEditor(
                      key: ValueKey(spec.key),
                      spec: spec,
                      value: node.params[spec.key] ?? spec.defaultValue,
                      nodeParams: node.params,
                      onChanged: (v) => controller.setParam(node, spec.key, v),
                      preview: (template) =>
                          controller.services.core.evaluateTemplate(template, controller.previewContext(node)),
                    ),
                    ?paramAssist(controller, node, spec),
                  ],
                ),
              ),
            if (type != null && !type.isTrigger) ...[
              const Divider(),
              SwitchRow(
                label: 'Disabled',
                subtitle: 'Passes items through without running',
                value: node.disabled,
                onChanged: (v) => controller.setFlags(node, disabled: v),
              ),
              SwitchRow(
                label: 'Continue on fail',
                subtitle: 'Outputs the error as an item instead of stopping',
                value: node.continueOnFail,
                onChanged: (v) => controller.setFlags(node, continueOnFail: v),
              ),
              SwitchRow(
                label: 'Retry on fail',
                subtitle: 'Tries a failed request again before giving up',
                value: node.retryOnFail,
                onChanged: (v) => controller.setRetry(node, enabled: v),
              ),
              if (node.retryOnFail) _RetrySettings(controller: controller, node: node),
            ],
            const Divider(),
            const FieldLabel('Connections'),
            if (outgoing.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Tap an output dot on the canvas, then a node, to connect.'),
              ),
            for (final c in outgoing)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.forward),
                title: Text(controller.workflow.node(c.to)?.name ?? c.to),
                subtitle: labels.length > 1 && c.output < labels.length ? Text('from "${labels[c.output]}"') : null,
                trailing: IconButton(
                  tooltip: 'Disconnect',
                  icon: const Icon(AppIcons.unlink),
                  onPressed: () => controller.disconnect(c),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RetrySettings extends StatelessWidget {
  const _RetrySettings({required this.controller, required this.node});

  final EditorController controller;
  final WorkflowNode node;

  static const _tries = [2, 3, 4, 5, 7, 10];
  static const _waits = [0, 1000, 5000, 10000, 30000, 60000, 300000];

  static String _waitLabel(int ms) => ms == 0 ? 'No wait' : (ms < 60000 ? '${ms ~/ 1000} s' : '${ms ~/ 60000} min');

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.sm),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FieldLabel('Tries in all'),
              DropdownButtonFormField<int>(
                initialValue: _tries.contains(node.maxTries) ? node.maxTries : 3,
                items: [for (final t in _tries) DropdownMenuItem(value: t, child: Text('$t'))],
                onChanged: (v) => controller.setRetry(node, enabled: true, maxTries: v),
                borderRadius: BorderRadius.circular(14),
                icon: const Icon(AppIcons.chevronDown),
              ),
            ],
          ),
        ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FieldLabel('Wait between'),
              DropdownButtonFormField<int>(
                initialValue: _waits.contains(node.waitBetweenTries) ? node.waitBetweenTries : 1000,
                items: [for (final w in _waits) DropdownMenuItem(value: w, child: Text(_waitLabel(w)))],
                onChanged: (v) => controller.setRetry(node, enabled: true, waitMs: v),
                borderRadius: BorderRadius.circular(14),
                icon: const Icon(AppIcons.chevronDown),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _OutputTab extends StatelessWidget {
  const _OutputTab({required this.controller, required this.node});

  final EditorController controller;
  final WorkflowNode node;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: controller, builder: (context, _) => _content(context));

  Widget _content(BuildContext context) {
    final run = controller.lastRunOf(node);
    final pinned = node.pinned;
    final c = AppColors.of(context);
    final pinBar = Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
        children: [
          Icon(AppIcons.pin, size: 18, color: pinned == null ? c.textTertiary : c.accent),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              pinned == null
                  ? 'Pin an output to reuse it in test runs instead of running this node again.'
                  : 'Pinned: test runs use these ${pinned.length} items instead of running this node.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ),
          if (pinned != null)
            TextButton(onPressed: () => controller.unpinOutput(node), child: const Text('Unpin'))
          else if (run != null && run.error == null)
            TextButton(onPressed: () => controller.pinOutput(node), child: const Text('Pin')),
          IconButton(
            tooltip: pinned == null ? 'Write test data' : 'Edit test data',
            icon: const Icon(AppIcons.edit, size: 18),
            onPressed: () => editPinnedData(context, controller, node),
          ),
        ],
      ),
    );
    if (run == null && pinned == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          pinBar,
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('Run the workflow to see this node\'s output.'),
          ),
        ],
      );
    }
    if (run == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          pinBar,
          JsonView(pinned, items: true, title: node.name),
        ],
      );
    }
    final files = fileRefsIn(run.outputs.expand((items) => items));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        pinBar,
        if (files.isNotEmpty) ...[FileCards(files), const SizedBox(height: Space.md)],
        if (run.error case final error?)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(padding: const EdgeInsets.all(12), child: Text(readableError(error))),
          ),
        for (final (i, items) in run.outputs.indexed) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              run.outputs.length > 1 ? 'Output ${i + 1}: ${itemCount(items.length)}' : itemCount(items.length),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          JsonView(items, items: true, title: run.outputs.length > 1 ? '${node.name} · output ${i + 1}' : node.name),
        ],
      ],
    );
  }
}

/// A small outlined action under the node's description.
class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap, this.accent = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// The main action: filled with the accent color.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: accent ? c.accent : c.grouped,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: accent ? Colors.white : c.textSecondary),
              const SizedBox(width: Space.sm),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: accent ? Colors.white : c.text, fontWeight: accent ? FontWeight.w600 : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for a curl command and fills [node]'s parameters from it.
Future<void> importCurlInto(BuildContext context, EditorController controller, WorkflowNode node) async {
  final request = await CurlImportSheet.show(context);
  if (request == null) return;
  controller.setParams(node, request.toParams());
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          request.notes.isEmpty
              ? 'Imported ${request.method} ${Uri.tryParse(request.url)?.host ?? ''}'
              : 'Imported. Note: ${request.notes.join('; ')}',
        ),
      ),
    );
  }
}

/// A sheet for pasting a curl command, parsed as it is typed.
class CurlImportSheet extends StatefulWidget {
  const CurlImportSheet({super.key, this.initial = ''});

  final String initial;

  static Future<CurlRequest?> show(BuildContext context) async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!context.mounted) return null;
    return showModalBottomSheet<CurlRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CurlImportSheet(initial: clip.startsWith('curl ') ? clip : ''),
    );
  }

  @override
  State<CurlImportSheet> createState() => _CurlImportSheetState();
}

class _CurlImportSheetState extends State<CurlImportSheet> {
  late final _text = TextEditingController(text: widget.initial);
  CurlRequest? _parsed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _parse() {
    final t = _text.text.trim();
    if (t.isEmpty) {
      _parsed = null;
      _error = null;
      return;
    }
    try {
      _parsed = parseCurl(t);
      _error = null;
    } on CurlFormatException catch (e) {
      _parsed = null;
      _error = 'Can’t read this yet: ${e.message}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final s = SyntaxColors.of(context);
    final p = _parsed;
    return Padding(
      padding: EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Import cURL', style: theme.textTheme.titleLarge),
          const SizedBox(height: Space.xs),
          Text(
            'Paste a curl command, for example from your browser’s “Copy as cURL” or an API’s docs.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _text,
            autofocus: widget.initial.isEmpty,
            minLines: 4,
            maxLines: 10,
            style: AppTheme.monospace.copyWith(color: c.text),
            decoration: const InputDecoration(hintText: "curl 'https://api.example.com' -H 'Accept: application/json'"),
            onChanged: (_) => setState(_parse),
          ),
          const SizedBox(height: Space.md),
          if (_error != null) Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: c.warning)),
          if (p != null)
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(color: c.grouped, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${p.method}  ',
                          style: TextStyle(color: s.keyword, fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: p.url),
                      ],
                    ),
                    style: AppTheme.monospace.copyWith(color: c.text),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    [
                      p.headers.length == 1 ? '1 header' : '${p.headers.length} headers',
                      if (p.body.isNotEmpty) 'body ${p.body.length} characters',
                      if (p.timeoutSeconds != null) 'timeout ${p.timeoutSeconds} s',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  for (final note in p.notes)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.xs),
                      child: Text('• $note', style: theme.textTheme.bodySmall?.copyWith(color: c.warning)),
                    ),
                ],
              ),
            ),
          const SizedBox(height: Space.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: Space.sm),
              FilledButton(onPressed: p == null ? null : () => Navigator.pop(context, p), child: const Text('Import')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Edits pinned test data as JSON: an object (one item) or a list of objects.
Future<void> editPinnedData(BuildContext context, EditorController controller, WorkflowNode node) async {
  final initial = const JsonEncoder.withIndent('  ').convert(node.pinned ?? [<String, Object?>{}]);
  final result = await Navigator.push<List<JsonMap>>(
    context,
    MaterialPageRoute(
      builder: (_) => _PinEditorPage(initial: initial, nodeName: node.name),
    ),
  );
  if (result != null) controller.setPinned(node, result);
}

class _PinEditorPage extends StatefulWidget {
  const _PinEditorPage({required this.initial, required this.nodeName});

  final String initial;
  final String nodeName;

  @override
  State<_PinEditorPage> createState() => _PinEditorPageState();
}

class _PinEditorPageState extends State<_PinEditorPage> {
  late final _text = HighlightController(text: widget.initial, mode: SyntaxMode.jsonTemplate);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  List<JsonMap>? _items() {
    try {
      final v = jsonDecode(_text.text);
      if (v is Map) return [asMap(v)];
      if (v is List && v.every((e) => e is Map)) return asMapList(v);
      _error = 'Use an object, or a list of objects (one per item).';
    } on FormatException catch (e) {
      _error = e.message;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    _text.colors = SyntaxColors.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Test data · ${widget.nodeName}'),
        actions: [
          IconButton(
            tooltip: 'Format',
            icon: const Icon(AppIcons.format),
            onPressed: () {
              final pretty = formatJsonTemplate(_text.text);
              if (pretty != null) _text.text = pretty;
              setState(() => _error = pretty == null ? 'Not valid JSON yet' : null);
            },
          ),
          Padding(
            padding: const EdgeInsets.only(right: Space.md),
            child: FilledButton(
              onPressed: () {
                final items = _items();
                if (items != null) {
                  Navigator.pop(context, items);
                } else {
                  setState(() {});
                }
              },
              child: const Text('Pin'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Text(
            'Test runs use this data instead of running the step. Write one object, or a list of objects for several items.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _text,
            minLines: 12,
            maxLines: null,
            autofocus: true,
            style: AppTheme.monospace.copyWith(color: c.text),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.danger)),
            ),
        ],
      ),
    );
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
