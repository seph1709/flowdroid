import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/flowcore.dart';
import '../../core/json.dart';
import '../../core/node_catalog.dart';
import '../credentials/credential_picker.dart';
import '../kit/kit.dart';
import 'advanced_params.dart';
import 'data_mapping.dart';
import '../widgets/syntax.dart';
import '../theme.dart';
import '../icons.dart';

/// Edits one node parameter according to its [ParamSpec.kind].
/// [preview] renders `{{ }}` expressions live, against the node's last input.
class ParamEditor extends StatelessWidget {
  const ParamEditor({
    super.key,
    required this.spec,
    required this.value,
    required this.onChanged,
    required this.preview,
    this.nodeParams = const {},
  });

  /// All of the node's parameters, for editors that depend on another one.
  final JsonMap nodeParams;
  final ParamSpec spec;
  final Object? value;
  final ValueChanged<Object?> onChanged;
  final Object? Function(String template) preview;

  @override
  Widget build(BuildContext context) => switch (spec.kind) {
    ParamKind.text => ExpressionField(
      label: spec.label,
      hint: spec.hint,
      value: _text(value),
      onChanged: onChanged,
      preview: preview,
    ),
    ParamKind.json => ExpressionField(
      label: spec.label,
      hint: spec.hint,
      value: _text(value),
      onChanged: onChanged,
      preview: preview,
      multiline: true,
    ),
    ParamKind.number => ExpressionField(
      label: spec.label,
      hint: spec.hint,
      value: _text(value),
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      onChanged: (text) => onChanged(num.tryParse(asString(text)) ?? text),
      preview: preview,
    ),
    ParamKind.boolean => SwitchRow(label: spec.label, value: value == true, onChanged: onChanged),
    ParamKind.select => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(spec.label),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: spec.options.contains(value) ? value as String? : null,
          items: [for (final o in spec.options) DropdownMenuItem(value: o, child: Text(_humanize(o)))],
          onChanged: onChanged,
          borderRadius: BorderRadius.circular(14),
          icon: const Icon(AppIcons.chevronDown),
        ),
      ],
    ),
    ParamKind.conditions || ParamKind.rules => RowListEditor(
      label: spec.label,
      rows: asMapList(value),
      onChanged: onChanged,
      newRow: () => {'left': '', 'op': 'equals', 'right': ''},
      rowBuilder: (row, update) => _ConditionRow(row: row, onChanged: update, preview: preview),
    ),
    ParamKind.credential => CredentialPicker(
      label: spec.label,
      types: spec.options,
      value: _text(value),
      onChanged: onChanged,
    ),
    ParamKind.workflow => WorkflowPicker(label: spec.label, value: _text(value), onChanged: onChanged),
    ParamKind.code => CodeField(
      label: spec.label,
      hint: spec.hint,
      value: _text(value),
      onChanged: onChanged,
      language: asString(nodeParams['language'], 'javascript'),
    ),
    ParamKind.tools => ToolsEditor(label: spec.label, rows: asMapList(value), onChanged: onChanged),
    ParamKind.fields || ParamKind.keyValues => RowListEditor(
      label: spec.label,
      rows: asMapList(value),
      onChanged: onChanged,
      newRow: () => {'name': '', 'value': ''},
      rowBuilder: (row, update) => _NameValueRow(row: row, onChanged: update, preview: preview),
    ),
  };

  static String _text(Object? v) => switch (v) {
    null => '',
    String s => s,
    num n => n == n.roundToDouble() ? n.toInt().toString() : n.toString(),
    _ => jsonEncode(v),
  };
}

/// A text field that understands `{{ }}` expressions and previews their value.
class ExpressionField extends StatefulWidget {
  const ExpressionField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.preview,
    this.hint,
    this.multiline = false,
    this.keyboardType,
  });

  final String label;
  final String? hint;
  final String value;
  final ValueChanged<String> onChanged;
  final Object? Function(String template) preview;
  final bool multiline;
  final TextInputType? keyboardType;

  @override
  State<ExpressionField> createState() => _ExpressionFieldState();
}

class _ExpressionFieldState extends State<ExpressionField> {
  late final _text =
      HighlightController(text: widget.value, mode: widget.multiline ? SyntaxMode.jsonTemplate : SyntaxMode.template)
        ..addListener(() {
          if (_focus.hasFocus) _updateSuggestions();
        });
  Timer? _debounce;
  String? _preview;
  bool _previewIsError = false;
  String? _jsonError;

  @override
  void initState() {
    super.initState();
    _updatePreview();
    _focus.addListener(_focusChanged);
  }

  final _focus = FocusNode();

  ({String partial, List<String> keys})? _suggest;

  void _focusChanged() {
    if (_focus.hasFocus) {
      MappingScope.of(context)?.focus(FieldTarget(label: widget.label, insert: _insert));
    }
    _updateSuggestions();
  }

  void _updateSuggestions() {
    final sources = MappingScope.of(context)?.sources;
    final next = sources == null || !_focus.hasFocus
        ? null
        : completions(_text.text, _text.selection.baseOffset, sources);
    if (next != _suggest) setState(() => _suggest = next);
  }

  void _complete(String key) {
    final s = _suggest;
    if (s == null) return;
    final v = _text.value;
    final at = v.selection.baseOffset;
    final ok = RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(key);
    // `$json.` + `name`, or `$json` + `["first name"]` when the key isn't a plain word.
    final start = at - s.partial.length - (ok ? 0 : 1);
    final piece = ok ? key : '["${key.replaceAll('"', r'\"')}"]';
    final updated = v.text.replaceRange(start, at, piece);
    _text.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + piece.length),
    );
    _changed(updated);
    _updateSuggestions();
  }

  @override
  void didUpdateWidget(ExpressionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rows can shift (one was removed), or a picker set the value: show it unless it
    // is just the echo of what the user is typing here.
    if (widget.value != _text.text && (!_focus.hasFocus || widget.value != _lastSent)) {
      _text.text = widget.value;
      _updatePreview();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The last value this field reported, to tell typing echoes from outside changes.
  String? _lastSent;

  void _changed(String text) {
    _lastSent = text;
    widget.onChanged(text);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(_updatePreview);
    });
  }

  void _updatePreview() {
    final text = _text.text;
    _jsonError = widget.multiline ? _checkJson(text) : null;
    if (!text.contains('{{')) {
      _preview = null;
      return;
    }
    try {
      final value = widget.preview(text);
      _preview = value is String ? value : jsonEncode(value);
      _previewIsError = false;
    } on FlowCoreException catch (e) {
      _preview = e.message;
      _previewIsError = true;
    }
  }

  /// Why [text] isn't valid JSON, when it looks like JSON and has no expressions to break it.
  static String? _checkJson(String text) {
    final t = text.trim();
    if (t.isEmpty || !(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      jsonDecode(t.replaceAll(RegExp(r'\{\{[\s\S]*?\}\}'), '0'));
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  void _insert(String expression) {
    final updated = insertExpression(_text.value, expression);
    _text.value = updated;
    _changed(updated.text);
    setState(_updatePreview);
  }

  Future<void> _pickData() async {
    final mapping = MappingScope.of(context);
    if (mapping == null) {
      _insert(r'$json.');
      _focus.requestFocus();
      return;
    }
    final expression = await DataPickerSheet.show(context, mapping.sources, widget.label);
    if (expression != null && mounted) _insert(expression);
  }

  /// Pretty-prints the JSON, keeping `{{ }}` expressions as they are.
  void _format() {
    final pretty = formatJsonTemplate(_text.text);
    if (pretty == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not valid JSON: ${_checkJson(_text.text) ?? 'check the brackets and quotes'}')),
      );
      return;
    }
    _text.text = pretty;
    _changed(pretty);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = AppColors.of(context);
    _text.colors = SyntaxColors.of(context);
    final mono = _text.text.contains('{{') || widget.multiline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: FieldLabel(widget.label, hint: widget.hint)),
            if (widget.multiline)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TextButton.icon(
                  onPressed: _format,
                  icon: const Icon(AppIcons.format, size: 16),
                  label: const Text('Format'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                    textStyle: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
          ],
        ),
        TextField(
          controller: _text,
          focusNode: _focus,
          keyboardType: widget.multiline ? TextInputType.multiline : widget.keyboardType,
          minLines: widget.multiline ? 4 : 1,
          maxLines: widget.multiline ? 14 : 4,
          style: mono ? AppTheme.monospace.copyWith(color: c.text) : null,
          decoration: InputDecoration(
            suffixIcon: IconButton(
              tooltip: 'Insert data',
              icon: const Icon(AppIcons.braces, size: 20),
              onPressed: _pickData,
            ),
          ),
          onChanged: _changed,
        ),
        if (_suggest case final suggest?)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: SizedBox(
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final key in suggest.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Material(
                        color: SyntaxColors.of(context).expressionBackground,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          canRequestFocus: false,
                          onTap: () => _complete(key),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            child: Text(
                              key,
                              style: AppTheme.monospace.copyWith(color: SyntaxColors.of(context).expression),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_jsonError case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.xs + 2, 0, 0),
            child: Text(
              'Not valid JSON yet: $error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.warning),
            ),
          ),
        if (_preview case final preview?)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.xs + 2, 0, 0),
            child: Semantics(
              label: _previewIsError ? 'Expression error: $preview' : 'Result: $preview',
              excludeSemantics: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _previewIsError ? AppIcons.error : AppIcons.result,
                    size: 16,
                    color: _previewIsError ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      preview.isEmpty ? '(empty)' : preview,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.monospace.copyWith(color: _previewIsError ? scheme.error : scheme.primary),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A list of object rows (conditions, fields, headers) with add and remove.
class RowListEditor extends StatelessWidget {
  const RowListEditor({
    super.key,
    required this.label,
    required this.rows,
    required this.onChanged,
    required this.newRow,
    required this.rowBuilder,
  });

  final String label;
  final List<JsonMap> rows;
  final ValueChanged<Object?> onChanged;
  final JsonMap Function() newRow;
  final Widget Function(JsonMap row, ValueChanged<JsonMap> update) rowBuilder;

  String get _noun => label.toLowerCase().replaceAll(RegExp(r's$'), '');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(label),
        for (final (i, row) in rows.indexed)
          Container(
            key: ValueKey(i),
            margin: const EdgeInsets.only(bottom: Space.sm),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.of(context).hairline),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.xs, Space.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: rowBuilder(row, (updated) => onChanged([...rows]..[i] = updated))),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(AppIcons.delete),
                    onPressed: () => onChanged([...rows]..removeAt(i)),
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(AppIcons.add, size: 18),
            label: Text(rows.isEmpty ? 'Add $_noun' : 'Add another'),
            onPressed: () => onChanged([...rows, newRow()]),
          ),
        ),
      ],
    );
  }
}

class _ConditionRow extends StatelessWidget {
  const _ConditionRow({required this.row, required this.onChanged, required this.preview});

  final JsonMap row;
  final ValueChanged<JsonMap> onChanged;
  final Object? Function(String template) preview;

  @override
  Widget build(BuildContext context) {
    final op = asString(row['op'], 'equals');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpressionField(
          label: 'Value',
          value: ParamEditor._text(row['left']),
          preview: preview,
          onChanged: (v) => onChanged({...row, 'left': v}),
        ),
        const SizedBox(height: 8),
        const FieldLabel('Operator'),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: conditionOperators.contains(op) ? op : 'equals',
          borderRadius: BorderRadius.circular(14),
          icon: const Icon(AppIcons.chevronDown),
          items: [for (final o in conditionOperators) DropdownMenuItem(value: o, child: Text(_operatorLabel(o)))],
          onChanged: (v) => onChanged({...row, 'op': v}),
        ),
        if (!unaryOperators.contains(op)) ...[
          const SizedBox(height: 8),
          ExpressionField(
            label: 'Compare to',
            value: ParamEditor._text(row['right']),
            preview: preview,
            onChanged: (v) => onChanged({...row, 'right': v}),
          ),
        ],
      ],
    );
  }
}

class _NameValueRow extends StatelessWidget {
  const _NameValueRow({required this.row, required this.onChanged, required this.preview});

  final JsonMap row;
  final ValueChanged<JsonMap> onChanged;
  final Object? Function(String template) preview;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpressionField(
          label: 'Name',
          value: ParamEditor._text(row['name']),
          preview: preview,
          onChanged: (v) => onChanged({...row, 'name': v}),
        ),
        const SizedBox(height: 8),
        ExpressionField(
          label: 'Value',
          value: ParamEditor._text(row['value']),
          preview: preview,
          onChanged: (v) => onChanged({...row, 'value': v}),
        ),
      ],
    );
  }
}

/// Friendlier names for a few options.
const _optionLabels = {
  'cron': 'On a calendar (days and times)',
  'interval': 'Every few minutes',
  'local': 'Words (offline, no key needed)',
  'collections': 'list knowledge bases',
  'sources': 'list sources',
  'file': 'file (saved in FlowDroid’s folder)',
  'claudeCode': 'Claude Code (your Claude plan, in Ubuntu)',
  'readFiles': 'Read files only',
  'editFiles': 'Read and change files',
  'runCommands': 'Change files and run commands',
  'http': 'A server on the web (HTTP)',
  'stdio': 'A command run in Ubuntu (stdio)',
  'saved': 'A saved MCP server',
  'freeSlots': 'find free time',
  'dndOn': 'Do Not Disturb on (total silence)',
  'dndPriority': 'Do Not Disturb: priority only',
  'dndAlarms': 'Do Not Disturb: alarms only',
  'dndOff': 'Do Not Disturb off',
  'showAlarms': 'show my alarms',
  'gallery': 'pick from the gallery',
  'scan': 'scan a document',
};

/// `notContains` → `not contains`, `combineByIndex` → `combine by index`.
String _humanize(String id) => _optionLabels[id] ?? _humanizeId(id);

String _humanizeId(String id) => id.replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]!.toLowerCase()}');

/// A label with a switch at the end; the whole row toggles.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.label, required this.value, required this.onChanged, this.subtitle});

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyLarge),
                    if (subtitle != null) Text(subtitle!, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

String _operatorLabel(String op) => switch (op) {
  'equals' => 'is equal to',
  'notEquals' => 'is not equal to',
  'contains' => 'contains',
  'notContains' => 'does not contain',
  'startsWith' => 'starts with',
  'endsWith' => 'ends with',
  'gt' => 'is greater than',
  'gte' => 'is at least',
  'lt' => 'is less than',
  'lte' => 'is at most',
  'isEmpty' => 'is empty',
  'isNotEmpty' => 'is not empty',
  'isTrue' => 'is true',
  'isFalse' => 'is false',
  _ => _humanize(op),
};

/// [text] as indented JSON with its `{{ }}` expressions kept verbatim, or null when it isn't JSON.
String? formatJsonTemplate(String text) {
  final exprs = <String>[];
  final out = StringBuffer();
  var inString = false;
  for (var i = 0; i < text.length; i++) {
    if (text.startsWith('{{', i)) {
      final end = text.indexOf('}}', i + 2);
      if (end < 0) return null;
      exprs.add(text.substring(i, end + 2));
      final marker = '__flowexpr${exprs.length - 1}__';
      out.write(inString ? marker : '"$marker"');
      i = end + 1;
      continue;
    }
    final ch = text[i];
    if (ch == r'\' && inString && i + 1 < text.length) {
      out.write(text.substring(i, i + 2));
      i++;
      continue;
    }
    if (ch == '"') inString = !inString;
    out.write(ch);
  }
  try {
    var pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(out.toString()));
    pretty = pretty.replaceAllMapped(RegExp(r'"__flowexpr(\d+)__"'), (m) => exprs[int.parse(m[1]!)]);
    return pretty.replaceAllMapped(RegExp(r'__flowexpr(\d+)__'), (m) => exprs[int.parse(m[1]!)]);
  } on FormatException {
    return null;
  }
}
