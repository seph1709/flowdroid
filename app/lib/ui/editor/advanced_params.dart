import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../core/workflow.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import 'param_editors.dart';
import '../widgets/syntax.dart';
import '../icons.dart';

/// Picks one of the saved workflows by id.
class WorkflowPicker extends StatelessWidget {
  const WorkflowPicker({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final repository = ServicesScope.of(context).repository;
    return ListenableBuilder(
      listenable: repository,
      builder: (context, _) => FutureBuilder<List<Workflow>>(
        future: repository.workflows(),
        builder: (context, snapshot) {
          final list = snapshot.data ?? const <Workflow>[];
          final ids = list.map((w) => w.id).toSet();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FieldLabel(label),
              DropdownButtonFormField<String>(
                key: ValueKey('${ids.length}|$value'),
                initialValue: ids.contains(value) ? value : null,
                hint: Text(list.isEmpty ? 'No workflows yet' : 'Choose…'),
                isExpanded: true,
                items: [
                  for (final w in list)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text(w.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (id) => onChanged(id ?? ''),
                borderRadius: BorderRadius.circular(14),
                icon: const Icon(AppIcons.chevronDown),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A monospaced editor for the Code node; `{{ }}` here is code, not an expression.
class CodeField extends StatefulWidget {
  const CodeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
    this.language = 'javascript',
  });

  final String label;
  final String? hint;
  final String value;
  final ValueChanged<String> onChanged;

  /// `javascript` or `python`, for coloring.
  final String language;

  @override
  State<CodeField> createState() => _CodeFieldState();
}

class _CodeFieldState extends State<CodeField> {
  late final _text = HighlightController(text: widget.value, mode: _mode);
  final _focus = FocusNode();

  SyntaxMode get _mode => widget.language == 'python' ? SyntaxMode.python : SyntaxMode.javascript;

  /// Keys that are slow to reach on a phone keyboard.
  List<String> get _keys => widget.language == 'python'
      ? const ['    ', ':', '(', ')', '[', ']', '{', '}', '"', "'", '=', '#', '.', '_']
      : const ['  ', '{', '}', '(', ')', '[', ']', ';', '=>', '"', "'", '`', '=', '.', r'$'];

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _type(String piece) {
    final v = _text.value;
    final sel = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    final updated = v.text.replaceRange(sel.start, sel.end, piece);
    _text.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: sel.start + piece.length),
    );
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    _text
      ..colors = SyntaxColors.of(context)
      ..mode = _mode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FieldLabel(widget.label, hint: widget.hint),
        TextField(
          controller: _text,
          focusNode: _focus,
          keyboardType: TextInputType.multiline,
          autocorrect: false,
          enableSuggestions: false,
          minLines: 8,
          maxLines: 22,
          style: AppTheme.monospace.copyWith(color: c.text),
          onChanged: widget.onChanged,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          child: !_focus.hasFocus
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final k in _keys)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Material(
                              color: c.grouped,
                              borderRadius: BorderRadius.circular(8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                // Keep the keyboard up while tapping.
                                canRequestFocus: false,
                                onTap: () => _type(k),
                                child: Container(
                                  constraints: const BoxConstraints(minWidth: 38),
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                                  child: Text(
                                    k.trim().isEmpty ? 'tab' : k,
                                    style: AppTheme.monospace.copyWith(
                                      color: k.trim().isEmpty ? c.textSecondary : c.text,
                                      fontSize: k.trim().isEmpty ? 12 : 14,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

const _toolKinds = {
  'http': 'Web API (HTTP)',
  'command': 'Shell command',
  'workflow': 'Another workflow',
  'table': 'Phone table',
  'mcp': 'MCP server (all its tools)',
  'browser': 'Web browser (with your logins)',
};

/// The AI Agent's tools: what each one does and how it is set up.
class ToolsEditor extends StatelessWidget {
  const ToolsEditor({super.key, required this.label, required this.rows, required this.onChanged});

  final String label;
  final List<JsonMap> rows;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) => RowListEditor(
    label: label,
    rows: rows,
    onChanged: onChanged,
    newRow: () => {'kind': 'http', 'name': 'tool_${rows.length + 1}', 'description': '', 'config': ''},
    rowBuilder: (row, update) => _ToolRow(row: row, onChanged: update),
  );
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.row, required this.onChanged});

  final JsonMap row;
  final ValueChanged<JsonMap> onChanged;

  @override
  Widget build(BuildContext context) {
    final kind = _toolKinds.containsKey(row['kind']) ? asString(row['kind']) : 'http';
    final config = asString(row['config']);
    Widget text(String label, String key, {String? hint}) =>
        _PlainField(label: label, hint: hint, value: asString(row[key]), onChanged: (v) => onChanged({...row, key: v}));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Kind'),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: kind,
          items: [for (final e in _toolKinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => onChanged({...row, 'kind': v, 'config': v == 'command' ? 'ubuntu' : ''}),
          borderRadius: BorderRadius.circular(14),
          icon: const Icon(AppIcons.chevronDown),
        ),
        const SizedBox(height: Space.sm),
        text('Name', 'name', hint: 'letters, digits, _ or -'),
        const SizedBox(height: Space.sm),
        text('What it is for', 'description', hint: 'tell Claude when to use it'),
        const SizedBox(height: Space.sm),
        switch (kind) {
          'command' => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const FieldLabel('Runs in'),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: config == 'phone' ? 'phone' : 'ubuntu',
                items: const [
                  DropdownMenuItem(value: 'ubuntu', child: Text('Ubuntu')),
                  DropdownMenuItem(value: 'phone', child: Text('Phone shell')),
                ],
                onChanged: (v) => onChanged({...row, 'config': v}),
                borderRadius: BorderRadius.circular(14),
                icon: const Icon(AppIcons.chevronDown),
              ),
            ],
          ),
          'workflow' => WorkflowPicker(
            label: 'Workflow it runs',
            value: config,
            onChanged: (v) => onChanged({...row, 'config': v}),
          ),
          'table' => text('Table name', 'config', hint: 'notes'),
          'browser' => text('Sites it may visit', 'config', hint: 'example.com, shop.example (empty = any site)'),
          'mcp' => text(
            'Server',
            'config',
            hint: 'a saved MCP server’s name, https://…/mcp, or a command run in Ubuntu',
          ),
          _ => text('Only URLs starting with', 'config', hint: 'https://api.example.com/  (empty = any)'),
        },
      ],
    );
  }
}

/// A plain text field without expressions.
class _PlainField extends StatefulWidget {
  const _PlainField({required this.label, required this.value, required this.onChanged, this.hint});

  final String label;
  final String? hint;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_PlainField> createState() => _PlainFieldState();
}

class _PlainFieldState extends State<_PlainField> {
  late final _text = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      FieldLabel(widget.label, hint: widget.hint),
      TextField(controller: _text, autocorrect: false, onChanged: widget.onChanged),
    ],
  );
}
