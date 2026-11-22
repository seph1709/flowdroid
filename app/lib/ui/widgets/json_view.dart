import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/json_path.dart';
import '../icons.dart';
import '../theme.dart';
import 'json_tree.dart';

enum JsonMode { tree, json, table }

/// Expression for a path into a node's output items: the item index is
/// dropped, because `$json` is already the current item.
String itemExpression(List<PathSegment> path) =>
    pathExpression(r'$json', path.isNotEmpty && path.first is int ? path.sublist(1) : path);

/// JSON in a quiet card: a foldable tree or colored text, with copy and a
/// full-screen viewer. Pass [items] when the value is a node's output items.
class JsonView extends StatefulWidget {
  const JsonView(this.value, {super.key, this.items = false, this.title, this.onPick, this.expression});

  final Object? value;
  final bool items;
  final String? title;
  final void Function(List<PathSegment> path, Object? value)? onPick;

  /// Expression for a path; defaults to `$json`-based.
  final String Function(List<PathSegment> path)? expression;

  @override
  State<JsonView> createState() => _JsonViewState();
}

class _JsonViewState extends State<JsonView> {
  late JsonTreeController _tree = JsonTreeController(widget.value, depth: widget.items ? 2 : 1);
  JsonMode _mode = JsonMode.tree;
  bool _allOpen = false;

  @override
  void didUpdateWidget(JsonView old) {
    super.didUpdateWidget(old);
    if (!identical(old.value, widget.value)) {
      _tree.dispose();
      _tree = JsonTreeController(widget.value, depth: widget.items ? 2 : 1);
    }
  }

  @override
  void dispose() {
    _tree.dispose();
    super.dispose();
  }

  String Function(List<PathSegment>) get _expression =>
      widget.expression ?? (widget.items ? itemExpression : (p) => pathExpression(r'$json', p));

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(widget.value)));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('JSON copied')));
  }

  void _openViewer() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => JsonViewerPage(value: widget.value, title: widget.title ?? 'Data', expression: _expression),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: c.grouped, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.xs, 0),
            child: Row(
              children: [
                _ModeSwitch(
                  mode: _mode,
                  modes: const [JsonMode.tree, JsonMode.json],
                  onChanged: (m) => setState(() => _mode = m),
                ),
                const Spacer(),
                if (_mode == JsonMode.tree)
                  _SmallButton(
                    tooltip: _allOpen ? 'Fold all' : 'Unfold all',
                    icon: _allOpen ? AppIcons.fold : AppIcons.unfold,
                    onPressed: () => setState(() {
                      _allOpen = !_allOpen;
                      _allOpen ? _tree.expandAll(widget.value) : _tree.collapseAll();
                    }),
                  ),
                _SmallButton(tooltip: 'Copy JSON', icon: AppIcons.copy, onPressed: _copy),
                _SmallButton(tooltip: 'Open viewer', icon: AppIcons.expand, onPressed: _openViewer),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.md),
            child: switch (_mode) {
              JsonMode.json => Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                child: JsonText(widget.value, maxLines: 300),
              ),
              _ => JsonTree(
                value: widget.value,
                controller: _tree,
                expression: _expression,
                onPick: widget.onPick,
                maxRows: 200,
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Full-screen JSON: search, tree, colored text and (for lists of objects) a table.
class JsonViewerPage extends StatefulWidget {
  const JsonViewerPage({super.key, required this.value, required this.title, required this.expression});

  final Object? value;
  final String title;
  final String Function(List<PathSegment> path) expression;

  @override
  State<JsonViewerPage> createState() => _JsonViewerPageState();
}

class _JsonViewerPageState extends State<JsonViewerPage> {
  late final _tree = JsonTreeController(widget.value, depth: 2);
  JsonMode _mode = JsonMode.tree;
  String _query = '';

  @override
  void dispose() {
    _tree.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canTable = JsonTable.canShow(widget.value);
    final size = utf8.encode(jsonEncode(widget.value)).length;
    final count = switch (widget.value) {
      List<Object?> l => l.length == 1 ? '1 item' : '${l.length} items',
      Map<Object?, Object?> m => m.length == 1 ? '1 key' : '${m.length} keys',
      _ => 'value',
    };
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            Text('$count · ${_bytes(size)}', style: theme.textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Copy JSON',
            icon: const Icon(AppIcons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(widget.value)));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('JSON copied')));
              }
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(AppIcons.search), hintText: 'Search keys and values'),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.sm, Space.xs),
            child: Row(
              children: [
                _ModeSwitch(
                  mode: _mode,
                  modes: [JsonMode.tree, JsonMode.json, if (canTable) JsonMode.table],
                  onChanged: (m) => setState(() => _mode = m),
                ),
                const Spacer(),
                if (_mode == JsonMode.tree) ...[
                  _SmallButton(tooltip: 'Fold all', icon: AppIcons.fold, onPressed: _tree.collapseAll),
                  _SmallButton(
                    tooltip: 'Unfold all',
                    icon: AppIcons.unfold,
                    onPressed: () => _tree.expandAll(widget.value),
                  ),
                ],
              ],
            ),
          ),
          Divider(color: AppColors.of(context).hairline),
          Expanded(
            child: switch (_mode) {
              JsonMode.tree => JsonTree(
                value: widget.value,
                controller: _tree,
                expression: widget.expression,
                query: _query,
                scrollable: true,
                padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.xxl),
              ),
              JsonMode.json => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
                child: JsonText(widget.value, query: _query),
              ),
              JsonMode.table => JsonTable(widget.value! as List<Object?>),
            },
          ),
        ],
      ),
    );
  }
}

String _bytes(int n) => n < 1024
    ? '$n B'
    : (n < 1024 * 1024 ? '${(n / 1024).toStringAsFixed(1)} KB' : '${(n / 1048576).toStringAsFixed(1)} MB');

/// A compact Tree | JSON | Table switch.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.modes, required this.onChanged});

  final JsonMode mode;
  final List<JsonMode> modes;
  final ValueChanged<JsonMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: c.hairline, borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in modes)
            Semantics(
              selected: m == mode,
              button: true,
              child: GestureDetector(
                onTap: () => onChanged(m),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: m == mode ? c.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: m == mode
                        ? [BoxShadow(color: c.shadow, blurRadius: 2, offset: const Offset(0, 1))]
                        : null,
                  ),
                  child: Text(switch (m) {
                    JsonMode.tree => 'Tree',
                    JsonMode.json => 'JSON',
                    JsonMode.table => 'Table',
                  }, style: theme.textTheme.labelMedium?.copyWith(color: m == mode ? c.text : c.textSecondary)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 18),
    onPressed: onPressed,
    style: IconButton.styleFrom(minimumSize: const Size(40, 40)),
  );
}
