import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/json_path.dart';
import '../icons.dart';
import '../theme.dart';
import 'syntax.dart';

/// Which branches of a [JsonTree] are open.
class JsonTreeController extends ChangeNotifier {
  JsonTreeController(Object? value, {int depth = 2}) : _open = containerPaths(value, depth: depth);

  Set<String> _open;
  Set<String>? _search;

  bool isOpen(String key) => (_search ?? _open).contains(key);

  void toggle(String key) {
    _search = null;
    _open = {..._open};
    if (!_open.remove(key)) _open.add(key);
    notifyListeners();
  }

  void expandAll(Object? value) {
    _search = null;
    _open = containerPaths(value);
    notifyListeners();
  }

  void collapseAll() {
    _search = null;
    _open = {pathKey(const [])};
    notifyListeners();
  }

  /// Opens exactly the branches that lead to a match; null ends the search.
  void showMatches(Set<String>? paths) {
    _search = paths;
    notifyListeners();
  }
}

/// One visible line of a tree.
class _Row {
  const _Row(this.path, this.value, this.depth);

  final List<PathSegment> path;
  final Object? value;
  final int depth;

  bool get isContainer => switch (value) {
    Map<Object?, Object?> m => m.isNotEmpty,
    List<Object?> l => l.isNotEmpty,
    _ => false,
  };
  String get key => pathKey(path);
}

List<_Row> _visibleRows(Object? root, JsonTreeController controller, {required bool hideRoot, Set<String>? only}) {
  final rows = <_Row>[];
  void walk(Object? v, List<PathSegment> path, int depth) {
    final key = pathKey(path);
    if (only != null && path.isNotEmpty && !only.contains(key)) return;
    if (!(hideRoot && path.isEmpty)) rows.add(_Row(path, v, depth));
    if (!(hideRoot && path.isEmpty) && !controller.isOpen(key)) return;
    final childDepth = hideRoot && path.isEmpty ? 0 : depth + 1;
    if (v is Map) {
      for (final MapEntry(key: k, value: child) in v.entries) {
        walk(child, [...path, '$k'], childDepth);
      }
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        walk(v[i], [...path, i], childDepth);
      }
    }
  }

  walk(root, const [], 0);
  return rows;
}

/// `{3}` / `[12]` / the scalar as JSON would print it, kept short.
String _summary(Object? v) => switch (v) {
  Map<Object?, Object?> m => m.isEmpty ? '{ }' : '{${m.length}}',
  List<Object?> l => l.isEmpty ? '[ ]' : '[${l.length}]',
  String s => s.isEmpty ? '""' : s,
  null => 'null',
  _ => '$v',
};

/// A JSON value as a foldable tree: tap a branch to open or close it, tap a
/// field to pick it (when [onPick] is set), long-press for copy actions.
class JsonTree extends StatelessWidget {
  const JsonTree({
    super.key,
    required this.value,
    required this.controller,
    this.expression = _defaultExpression,
    this.onPick,
    this.hideRoot = true,
    this.maxRows,
    this.query = '',
    this.scrollable = false,
    this.padding = EdgeInsets.zero,
  });

  final Object? value;
  final JsonTreeController controller;

  /// The expression that reads [path], used for copying and picking.
  final String Function(List<PathSegment> path) expression;
  final void Function(List<PathSegment> path, Object? value)? onPick;
  final bool hideRoot;

  /// Rows shown before "N more"; null shows all (use with [scrollable]).
  final int? maxRows;
  final String query;
  final bool scrollable;
  final EdgeInsets padding;

  static String _defaultExpression(List<PathSegment> path) => pathExpression(r'$json', path);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final only = query.isEmpty ? null : matchingPaths(value, query);
      final rows = _visibleRows(value, controller, hideRoot: hideRoot, only: only);
      if (rows.isEmpty) {
        return Padding(
          padding: padding.add(const EdgeInsets.all(Space.md)),
          child: Text(
            only != null ? 'Nothing matches "$query"' : (value is List ? 'No items' : 'Empty'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      final shown = maxRows == null || rows.length <= maxRows! ? rows : rows.sublist(0, maxRows);
      Widget line(_Row r) => _TreeLine(
        row: r,
        open: r.isContainer && (only != null || controller.isOpen(r.key)),
        onToggle: () => controller.toggle(r.key),
        onPick: onPick,
        expression: expression,
        query: query,
      );
      if (scrollable) {
        return ListView.builder(padding: padding, itemCount: shown.length, itemBuilder: (_, i) => line(shown[i]));
      }
      return Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in shown) line(r),
            if (shown.length < rows.length)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, 0, 0),
                child: Text(
                  '${rows.length - shown.length} more lines: open the viewer to see them all',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _TreeLine extends StatelessWidget {
  const _TreeLine({
    required this.row,
    required this.open,
    required this.onToggle,
    required this.onPick,
    required this.expression,
    required this.query,
  });

  final _Row row;
  final bool open;
  final VoidCallback onToggle;
  final void Function(List<PathSegment> path, Object? value)? onPick;
  final String Function(List<PathSegment> path) expression;
  final String query;

  static const _indent = 14.0;

  Future<void> _actions(BuildContext context) async {
    final expr = expression(row.path);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: Text(expr, style: AppTheme.monospace.copyWith(color: SyntaxColors.of(context).expression)),
            ),
            if (onPick != null)
              ListTile(
                leading: const Icon(AppIcons.insert),
                title: const Text('Insert into field'),
                onTap: () => Navigator.pop(context, 'pick'),
              ),
            ListTile(
              leading: const Icon(AppIcons.braces),
              title: const Text('Copy expression'),
              subtitle: Text('{{ $expr }}', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(context, 'expr'),
            ),
            ListTile(
              leading: const Icon(AppIcons.copy),
              title: const Text('Copy value'),
              onTap: () => Navigator.pop(context, 'value'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'pick':
        onPick!(row.path, row.value);
        return;
      case 'expr':
        await Clipboard.setData(ClipboardData(text: '{{ $expr }}'));
      case 'value':
        final v = row.value;
        await Clipboard.setData(ClipboardData(text: v is String ? v : const JsonEncoder.withIndent('  ').convert(v)));
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(action == 'expr' ? 'Expression copied' : 'Value copied')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = SyntaxColors.of(context);
    final mono = AppTheme.monospace;
    final last = row.path.isEmpty ? null : row.path.last;
    final keyText = switch (last) {
      int i => '$i',
      String k => k,
      _ => 'root',
    };
    final v = row.value;
    final hit = query.isNotEmpty;
    TextSpan mark(String text, TextStyle style) {
      if (!hit) return TextSpan(text: text, style: style);
      final at = text.toLowerCase().indexOf(query.toLowerCase());
      if (at < 0) return TextSpan(text: text, style: style);
      return TextSpan(
        style: style,
        children: [
          TextSpan(text: text.substring(0, at)),
          TextSpan(
            text: text.substring(at, at + query.length),
            style: TextStyle(backgroundColor: s.match),
          ),
          TextSpan(text: text.substring(at + query.length)),
        ],
      );
    }

    final label = Text.rich(
      TextSpan(
        children: [
          mark(keyText, mono.copyWith(color: last is int ? s.punctuation : s.key, fontWeight: FontWeight.w500)),
          TextSpan(text: '  ', style: mono),
          if (row.isContainer)
            TextSpan(
              text: _summary(v),
              style: mono.copyWith(color: c.textTertiary),
            )
          else
            mark(_summary(v), mono.copyWith(color: s.forValue(v))),
        ],
      ),
      maxLines: row.isContainer ? 1 : 4,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      button: true,
      label: row.isContainer ? '$keyText, ${open ? 'open' : 'closed'}' : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: row.isContainer ? onToggle : (onPick == null ? () => _actions(context) : () => onPick!(row.path, v)),
        onLongPress: () => _actions(context),
        child: CustomPaint(
          painter: _GuidePainter(row.depth, _indent, c.hairline),
          child: Padding(
            padding: EdgeInsets.only(left: row.depth * _indent, top: 5, bottom: 5, right: Space.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 18,
                  height: 19,
                  child: row.isContainer
                      ? AnimatedRotation(
                          turns: open ? 0.25 : 0,
                          duration: const Duration(milliseconds: 140),
                          child: Icon(AppIcons.chevronRight, size: 14, color: c.textTertiary),
                        )
                      : null,
                ),
                Expanded(child: label),
                if (onPick != null && !row.isContainer)
                  Padding(
                    padding: const EdgeInsets.only(left: Space.xs, top: 1),
                    child: Icon(AppIcons.insert, size: 15, color: c.textTertiary),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Faint vertical lines that show how deep a row is.
class _GuidePainter extends CustomPainter {
  const _GuidePainter(this.depth, this.indent, this.color);

  final int depth;
  final double indent;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var d = 0; d < depth; d++) {
      final x = d * indent + 8.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) => old.depth != depth || old.color != color;
}

/// Pretty-printed JSON, colored and selectable; long text is cut at [maxLines].
class JsonText extends StatelessWidget {
  const JsonText(this.value, {super.key, this.maxLines, this.query = ''});

  final Object? value;
  final int? maxLines;
  final String query;

  @override
  Widget build(BuildContext context) {
    var text = const JsonEncoder.withIndent('  ').convert(value);
    var cut = 0;
    if (maxLines != null) {
      final lines = text.split('\n');
      if (lines.length > maxLines!) {
        cut = lines.length - maxLines!;
        text = lines.take(maxLines!).join('\n');
      }
    }
    final s = SyntaxColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText.rich(TextSpan(style: AppTheme.monospace, children: jsonSpans(text, s))),
        ),
        if (cut > 0)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(
              '$cut more lines: open the viewer to see them all',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// A list of objects as rows and columns, one column per key.
class JsonTable extends StatelessWidget {
  const JsonTable(this.items, {super.key});

  final List<Object?> items;

  static bool canShow(Object? value) => value is List && value.isNotEmpty && value.every((e) => e is Map);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = SyntaxColors.of(context);
    final columns = <String>[];
    for (final item in items.whereType<Map<Object?, Object?>>()) {
      for (final k in item.keys) {
        if (!columns.contains('$k') && columns.length < 40) columns.add('$k');
      }
    }
    const width = 156.0;
    const indexWidth = 44.0;
    final headStyle = Theme.of(context).textTheme.labelMedium?.copyWith(color: c.text);
    Widget cell(Widget child, {double w = width}) => Container(
      width: w,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.sm),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: c.hairline)),
      ),
      child: child,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: indexWidth + columns.length * width,
        child: Column(
          children: [
            Container(
              color: c.grouped,
              child: Row(
                children: [
                  cell(Text('#', style: headStyle), w: indexWidth),
                  for (final col in columns)
                    cell(Text(col, style: headStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i]! as Map<Object?, Object?>;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.hairline)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        cell(
                          Text('$i', style: AppTheme.monospace.copyWith(color: c.textTertiary)),
                          w: indexWidth,
                        ),
                        for (final col in columns)
                          cell(
                            Text(
                              item.containsKey(col) ? _summary(item[col]) : '',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.monospace.copyWith(
                                color: item[col] is Map || item[col] is List ? c.textTertiary : s.forValue(item[col]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
