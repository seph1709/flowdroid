/// Mapping data from earlier steps into a node's fields: the sources a node
/// can read, the field that receives a tapped value, and the pickers.
library;

import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../core/json_path.dart';
import '../../core/workflow.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../theme.dart';
import '../widgets/json_view.dart';
import '../widgets/syntax.dart';
import 'editor_controller.dart';

/// Data a node can read in its expressions, with the expression for its root.
class DataSource {
  const DataSource({required this.title, required this.root, required this.value, this.subtitle, this.items = false});

  final String title;
  final String? subtitle;

  /// `$json`, `$node["Fetch"].json`, `$vars`…
  final String root;
  final Object? value;

  /// [value] is a list of items; paths skip the item index.
  final bool items;

  String expression(List<PathSegment> path) =>
      pathExpression(root, items && path.isNotEmpty && path.first is int ? path.sublist(1) : path);
}

/// The text field that receives a picked value.
class FieldTarget {
  const FieldTarget({required this.label, required this.insert});

  final String label;
  final void Function(String expression) insert;
}

/// Shared by a node sheet: which field was focused last, and where data comes from.
class MappingController extends ChangeNotifier {
  MappingController(this.sources);

  final List<DataSource> sources;
  FieldTarget? _target;
  VoidCallback? onInserted;

  FieldTarget? get target => _target;

  void focus(FieldTarget target) {
    _target = target;
    notifyListeners();
  }

  void pick(DataSource source, List<PathSegment> path) {
    final t = _target;
    if (t == null) return;
    t.insert(source.expression(path));
    onInserted?.call();
  }

  /// Sources for [node]: its input, each earlier step that has run, variables and context.
  static List<DataSource> sourcesFor(EditorController controller, WorkflowNode node) {
    final record = controller.lastExecution;
    final wf = controller.workflow;
    final out = <DataSource>[];

    List<JsonMap> itemsOf(WorkflowNode n, [int? port]) {
      final pinned = n.pinned;
      final run = record?.runOf(n.id);
      if (run == null) return pinned ?? const [];
      if (port != null) return port < run.outputs.length ? run.outputs[port] : const [];
      return run.outputs.expand((i) => i).toList();
    }

    String? inputFrom;
    final incoming = wf.connections.where((c) => c.to == node.id).toList();
    for (final c in incoming) {
      final from = wf.node(c.from);
      if (from == null) continue;
      final items = itemsOf(from, c.output);
      if (items.isEmpty) continue;
      out.add(
        DataSource(
          title: 'Input',
          subtitle: 'from ${from.name} · ${items.length == 1 ? '1 item' : '${items.length} items'}',
          root: r'$json',
          value: items,
          items: true,
        ),
      );
      inputFrom = from.id;
      break;
    }

    // Every earlier step, nearest first.
    final seen = <String>{node.id};
    var frontier = [node.id];
    while (frontier.isNotEmpty) {
      final next = <String>[];
      for (final id in frontier) {
        for (final c in wf.connections.where((c) => c.to == id)) {
          if (!seen.add(c.from)) continue;
          next.add(c.from);
          final n = wf.node(c.from);
          // The direct input is already listed as Input.
          if (n == null || n.id == inputFrom) continue;
          final items = itemsOf(n);
          if (items.isEmpty) continue;
          out.add(
            DataSource(
              title: n.name,
              subtitle: items.length == 1 ? '1 item' : '${items.length} items',
              root: '\$node["${n.name.replaceAll('"', r'\"')}"].json',
              value: items,
              items: true,
            ),
          );
        }
      }
      frontier = next;
    }

    if (wf.variables.isNotEmpty) {
      out.add(DataSource(title: 'Variables', subtitle: r'$vars', root: r'$vars', value: wf.variables));
    }
    out.add(
      DataSource(
        title: 'Workflow and time',
        root: r'$',
        value: {
          'now': DateTime.now().toUtc().toIso8601String(),
          'index': 0,
          'workflow': {'id': wf.id, 'name': wf.name},
        },
      ),
    );
    return out;
  }
}

/// Maps `$.now` → `$now`, `$.workflow.name` → `$workflow.name` for the context source.
String _contextFix(String expr) => expr.startsWith(r'$.') ? '\$${expr.substring(2)}' : expr;

/// The data a node receives, for tapping fields into its parameters.
class InputPanel extends StatelessWidget {
  const InputPanel({super.key, required this.mapping, required this.scroll});

  final MappingController mapping;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: mapping,
    builder: (context, _) {
      final theme = Theme.of(context);
      final c = AppColors.of(context);
      final target = mapping.target;
      final hasData = mapping.sources.any((s) => s.items);
      return ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, Space.xxl),
        children: [
          _Hint(
            icon: target == null ? AppIcons.insert : AppIcons.result,
            text: target == null
                ? 'Tap a field in Parameters, then come back and tap a value to insert it. Long-press a value to copy it.'
                : 'Tap a value to insert it into “${target.label}”.',
            active: target != null,
          ),
          if (!hasData)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xl),
              child: Text(
                'No input yet. Run the workflow once (or pin data on an earlier step) to see what arrives here.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.textSecondary),
              ),
            ),
          for (final source in mapping.sources) ...[
            const SizedBox(height: Space.lg),
            _SourceTitle(source),
            const SizedBox(height: Space.sm),
            JsonView(
              source.value,
              items: source.items,
              title: source.title,
              expression: _Fixed(source).expression,
              onPick: target == null ? null : (path, _) => mapping.pick(_Fixed(source), path),
            ),
          ],
        ],
      );
    },
  );
}

/// A source whose expressions get the `$now`/`$workflow` fix.
class _Fixed extends DataSource {
  _Fixed(DataSource s) : super(title: s.title, root: s.root, value: s.value, items: s.items, subtitle: s.subtitle);

  @override
  String expression(List<PathSegment> path) => _contextFix(super.expression(path));
}

class _SourceTitle extends StatelessWidget {
  const _SourceTitle(this.source);

  final DataSource source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(source.title, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
        ),
        if (source.subtitle case final sub?) ...[
          const SizedBox(width: Space.sm),
          Text(sub, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, required this.active});

  final IconData icon;
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
      decoration: BoxDecoration(color: active ? c.accentSoft : c.grouped, borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: active ? c.accent : c.textSecondary),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: active ? c.accent : c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Snippets offered under the data in the picker.
const _snippets = <(String, String)>[
  (r'$json', 'The whole item'),
  (r'JSON.stringify($json)', 'The item as text'),
  (r'$items.length', 'How many items arrived'),
  (r'$index', 'This item’s position'),
  (r'$now', 'Current time (UTC)'),
  (r'$json.name ?? "unknown"', 'A fallback when a field is missing'),
  (r'$json.active ? "yes" : "no"', 'Choose by a condition'),
  (r'$json.email.toLowerCase()', 'Text helpers: toUpperCase, trim, split, replace…'),
  (r'Math.round($json.price * 100) / 100', 'Math: round, floor, ceil, min, max, abs'),
];

/// Bottom sheet for choosing data for one field; pops the chosen expression.
class DataPickerSheet extends StatefulWidget {
  const DataPickerSheet({super.key, required this.sources, required this.fieldLabel});

  final List<DataSource> sources;
  final String fieldLabel;

  static Future<String?> show(BuildContext context, List<DataSource> sources, String fieldLabel) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => DataPickerSheet(sources: sources, fieldLabel: fieldLabel),
      );

  @override
  State<DataPickerSheet> createState() => _DataPickerSheetState();
}

class _DataPickerSheetState extends State<DataPickerSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = SyntaxColors.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xxl),
        children: [
          Text('Insert into “${widget.fieldLabel}”', style: theme.textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Text('Tap a value. It goes in as an expression and updates on every run.', style: theme.textTheme.bodySmall),
          if (!widget.sources.any((s) => s.items))
            Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: Text(
                'Run the workflow once to see the data from earlier steps here.',
                style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.of(context).textSecondary),
              ),
            ),
          for (final source in widget.sources) ...[
            const SizedBox(height: Space.lg),
            _SourceTitle(source),
            const SizedBox(height: Space.sm),
            JsonView(
              source.value,
              items: source.items,
              title: source.title,
              expression: _Fixed(source).expression,
              onPick: (path, _) => Navigator.pop(context, _Fixed(source).expression(path)),
            ),
          ],
          const SectionLabel('SNIPPETS', padding: EdgeInsets.fromLTRB(2, Space.xl, 0, Space.sm)),
          GroupedSection(
            margin: EdgeInsets.zero,
            children: [
              for (final (expr, what) in _snippets)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  title: Text(expr, style: AppTheme.monospace.copyWith(color: s.expression)),
                  subtitle: Text(what),
                  onTap: () => Navigator.pop(context, expr),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Lets fields deep in a node sheet reach its [MappingController].
class MappingScope extends InheritedWidget {
  const MappingScope({super.key, required this.mapping, required super.child});

  final MappingController mapping;

  static MappingController? of(BuildContext context) => context.getInheritedWidgetOfExactType<MappingScope>()?.mapping;

  @override
  bool updateShouldNotify(MappingScope old) => old.mapping != mapping;
}

/// Puts [expression] into [text] at the selection: bare inside an open `{{ }}`, else wrapped.
TextEditingValue insertExpression(TextEditingValue value, String expression) {
  final text = value.text;
  final sel = value.selection;
  final start = sel.isValid ? sel.start : text.length;
  final end = sel.isValid ? sel.end : text.length;
  final before = text.substring(0, start);
  final inside = before.lastIndexOf('{{') > before.lastIndexOf('}}');
  final piece = inside ? expression : '{{ $expression }}';
  final updated = text.replaceRange(start, end, piece);
  return TextEditingValue(
    text: updated,
    selection: TextSelection.collapsed(offset: start + piece.length),
  );
}

final _completable = RegExp(
  r'(\$json|\$vars|\$node\["((?:[^"\\]|\\.)*)"\]\.json)((?:\.[A-Za-z_$][\w$]*|\[\d+\])*)\.([A-Za-z_$][\w$]*)?$',
);
final _segment = RegExp(r'\.([A-Za-z_$][\w$]*)|\[(\d+)\]');

/// Field names that can follow what is typed before [cursor], when it ends in
/// `$json.`, `$node["X"].json.a.` or `$vars.` inside `{{ }}`. Returns the
/// partial word being typed and the matching keys.
({String partial, List<String> keys})? completions(String text, int cursor, List<DataSource> sources) {
  if (cursor < 0 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  if (before.lastIndexOf('{{') <= before.lastIndexOf('}}')) return null;
  final m = _completable.firstMatch(before);
  if (m == null) return null;
  Object? base;
  final root = m[1]!;
  if (root == r'$json') {
    base = sources.where((s) => s.title == 'Input').map((s) => (s.value as List?)?.firstOrNull).firstOrNull;
  } else if (root == r'$vars') {
    base = sources.where((s) => s.root == r'$vars').map((s) => s.value).firstOrNull;
  } else {
    final name = m[2]!.replaceAll(r'\"', '"');
    base = sources
        .where((s) => s.items && s.root == '\$node["${name.replaceAll('"', r'\"')}"].json')
        .map((s) => (s.value as List?)?.firstOrNull)
        .firstOrNull;
  }
  final path = <PathSegment>[for (final seg in _segment.allMatches(m[3] ?? '')) seg[1] ?? int.parse(seg[2]!)];
  final target = valueAt(base, path);
  if (target is! Map) return null;
  final partial = m[4] ?? '';
  final keys = [
    for (final k in target.keys)
      if ('$k'.toLowerCase().startsWith(partial.toLowerCase()) && '$k' != partial) '$k',
  ];
  return keys.isEmpty ? null : (partial: partial, keys: keys.take(24).toList());
}
