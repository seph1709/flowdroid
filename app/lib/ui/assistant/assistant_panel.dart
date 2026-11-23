import 'package:material_ui/material_ui.dart';

import '../../assistant/assistant_chat.dart';
import '../../assistant/workflow_tools.dart';
import '../editor/editor_controller.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import 'assistant_settings_page.dart';

/// The assistant's chat over the editor: it builds and fixes the workflow on
/// the canvas while you talk to it.
class AssistantPanel extends StatefulWidget {
  const AssistantPanel({super.key, required this.controller, this.firstMessage, this.onCanvasChanged});

  final EditorController controller;

  /// The assistant edited the workflow (the editor brings the steps into view).
  final VoidCallback? onCanvasChanged;

  /// Sent as soon as the panel opens (e.g. from “Describe it to the assistant”).
  final String? firstMessage;

  static Future<void> show(
    BuildContext context,
    EditorController controller, {
    String? firstMessage,
    VoidCallback? onCanvasChanged,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: 0.12),
    builder: (_) =>
        AssistantPanel(controller: controller, firstMessage: firstMessage, onCanvasChanged: onCanvasChanged),
  );

  @override
  State<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends State<AssistantPanel> {
  late final AssistantChat _chat = AssistantChat.of(widget.controller.workflow.id);
  final _input = TextEditingController();
  final _scroll = ScrollController();
  AssistantConfig? _config;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _chat.addListener(_toBottom);
    _loadConfig().then((_) {
      final first = widget.firstMessage;
      if (first != null && first.trim().isNotEmpty) _send(first);
    });
  }

  @override
  void dispose() {
    _chat.removeListener(_toBottom);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final services = ServicesScope.of(context);
    final config = await AssistantConfig.load(services.dataDir);
    if (!mounted) return;
    if (config.ready) _chat.configure(config, services);
    setState(() => _config = config);
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _openSettings() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AssistantSettingsPage()));
    await _loadConfig();
  }

  WorkflowTools _tools() {
    final services = ServicesScope.of(context);
    return WorkflowTools(
      controller: widget.controller,
      approveRun: _approveRun,
      onChanged: widget.onCanvasChanged,
      credentialNames: () async => [
        for (final c in await services.credentials.all()) {'name': c.name, 'type': c.type},
      ],
      workflowList: () async => [
        for (final w in await services.repository.workflows()) {'id': w.id, 'name': w.name},
      ],
    );
  }

  Future<bool> _approveRun(String what) async {
    if (_chat.runsApproved) return true;
    if (!mounted) return false;
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Let the assistant run it?'),
        content: Text(
          'It wants to $what. The steps really run: messages may be sent, APIs called and phone actions done.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'no'), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(context, 'chat'), child: const Text('Always in this chat')),
          FilledButton(onPressed: () => Navigator.pop(context, 'once'), child: const Text('Run')),
        ],
      ),
    );
    if (answer == 'chat') _chat.runsApproved = true;
    return answer == 'once' || answer == 'chat';
  }

  void _send([String? text]) {
    final message = (text ?? _input.text).trim();
    if (message.isEmpty || _chat.busy) return;
    final config = _config;
    if (config == null || !config.ready) {
      _openSettings();
      return;
    }
    _input.clear();
    _chat.send(message, _tools());
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.66,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      snap: true,
      snapSizes: const [0.4, 0.66, 0.95],
      builder: (context, sheetScroll) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListenableBuilder(
          listenable: _chat,
          builder: (context, _) => Column(
            children: [
              _Header(
                scroll: sheetScroll,
                label: _config == null ? null : (_config!.ready ? _chat.engineLabel ?? _config!.label : 'Not set up'),
                onSettings: _openSettings,
                onNew: _chat.entries.isEmpty || _chat.busy ? null : _chat.clear,
              ),
              Expanded(child: _body()),
              if (_config?.ready ?? false)
                _Composer(controller: _input, busy: _chat.busy, onSend: _send, onStop: _chat.stop),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final config = _config;
    if (config == null) return const Center(child: QuietSpinner());
    if (!config.ready) return _SetUp(onSetUp: _openSettings);
    if (_chat.entries.isEmpty) {
      return _Suggestions(empty: widget.controller.workflow.nodes.isEmpty, onPick: _send);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.page, Space.lg),
      itemCount: _chat.entries.length + (_chat.busy ? 1 : 0),
      itemBuilder: (context, i) => i == _chat.entries.length ? const _Working() : _EntryView(entry: _chat.entries[i]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.scroll, required this.label, required this.onSettings, required this.onNew});

  final ScrollController scroll;
  final String? label;
  final VoidCallback onSettings;
  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    // A scrollable so dragging the header resizes the sheet.
    return SingleChildScrollView(
      controller: scroll,
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.sm, Space.xs),
        child: Row(
          children: [
            GlyphIcon(icon: AppIcons.sparkle, color: AppColors.of(context).accent, size: 32),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Assistant', style: theme.textTheme.titleMedium),
                  if (label != null)
                    GestureDetector(
                      onTap: onSettings,
                      child: Text(
                        label!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            if (onNew != null) IconButton(tooltip: 'New chat', icon: const Icon(AppIcons.sweep), onPressed: onNew),
            IconButton(tooltip: 'Assistant settings', icon: const Icon(AppIcons.tune), onPressed: onSettings),
          ],
        ),
      ),
    );
  }
}

class _SetUp extends StatelessWidget {
  const _SetUp({required this.onSetUp});

  final VoidCallback onSetUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(Space.page),
      children: [
        Text('Choose the AI', style: theme.textTheme.titleSmall),
        const SizedBox(height: Space.xs),
        Text(
          'Use an API key (Anthropic, OpenAI, Gemini, Ollama, OpenRouter, …), or your own Claude or ChatGPT plan '
          'through Claude Code or Codex in Ubuntu.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(icon: const Icon(AppIcons.tune), label: const Text('Set up'), onPressed: onSetUp),
        ),
      ],
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.empty, required this.onPick});

  final bool empty;
  final void Function(String) onPick;

  static const _build = [
    'Every morning at 7, notify me of today’s weather',
    'When an SMS has a verification code, copy the code',
    'Save links I share to my notes, then let me ask them questions',
  ];

  static const _work = [
    'Explain what this workflow does',
    'Test it and fix any problems',
    'Why did the last run fail?',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.page, Space.lg),
      children: [
        Text(
          empty
              ? 'Say what should happen, and when. It adds the steps, sets them up and can test them.'
              : 'Ask it to change, explain, test or fix this workflow.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.md),
        for (final s in empty ? _build : _work)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: Material(
              color: c.grouped,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onPick(s),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
                  child: Row(
                    children: [
                      Expanded(child: Text(s, style: theme.textTheme.bodyMedium)),
                      Icon(AppIcons.forward, size: 18, color: c.textTertiary),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final ChatEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    switch (entry.role) {
      case ChatRole.person:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
            margin: const EdgeInsets.only(top: Space.md, bottom: Space.sm),
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
            decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(16)),
            child: SelectableText(entry.text, style: theme.textTheme.bodyMedium?.copyWith(color: c.text)),
          ),
        );
      case ChatRole.assistant:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          child: SelectableText.rich(formatReply(entry.text, theme, c)),
        );
      case ChatRole.action:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                entry.isError ? AppIcons.warning : AppIcons.check,
                size: 15,
                color: entry.isError ? c.warning : c.textTertiary,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  entry.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
        );
      case ChatRole.failure:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: Space.sm),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(color: c.dangerSoft, borderRadius: BorderRadius.circular(12)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(AppIcons.error, size: 18, color: c.danger),
              const SizedBox(width: Space.sm),
              Expanded(
                child: SelectableText(entry.text, style: theme.textTheme.bodySmall?.copyWith(color: c.text)),
              ),
            ],
          ),
        );
    }
  }
}

/// Light Markdown for replies: headings, **bold**, `code` and bullets.
TextSpan formatReply(String text, ThemeData theme, AppColors c) {
  final base = theme.textTheme.bodyMedium?.copyWith(color: c.text, height: 1.45);
  final bold = base?.copyWith(fontWeight: FontWeight.w600);
  final code = base?.copyWith(
    fontFamily: 'monospace',
    fontSize: (base.fontSize ?? 14) * 0.92,
    backgroundColor: c.grouped,
  );
  final spans = <InlineSpan>[];
  final lines = text.split('\n');
  for (final (i, raw) in lines.indexed) {
    var line = raw;
    var style = base;
    final heading = RegExp(r'^#{1,6}\s+').firstMatch(line);
    if (heading != null) {
      line = line.substring(heading.end);
      style = bold;
    }
    final bullet = RegExp(r'^(\s*)[-*]\s+').firstMatch(line);
    if (bullet != null) line = '${bullet[1]}•  ${line.substring(bullet.end)}';
    if (line.trim() == '```') continue;
    final parts = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`').allMatches(line);
    var at = 0;
    for (final m in parts) {
      if (m.start > at) spans.add(TextSpan(text: line.substring(at, m.start), style: style));
      spans.add(m[1] != null ? TextSpan(text: m[1], style: bold) : TextSpan(text: m[2], style: code));
      at = m.end;
    }
    spans.add(TextSpan(text: line.substring(at) + (i < lines.length - 1 ? '\n' : ''), style: style));
  }
  return TextSpan(children: spans, style: base);
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Space.sm),
    child: Row(
      children: [
        const QuietSpinner(size: 16),
        const SizedBox(width: Space.sm),
        Text('Working…', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.busy, required this.onSend, required this.onStop});

  final TextEditingController controller;
  final bool busy;
  final void Function([String?]) onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(hintText: 'Ask or describe a workflow'),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: Space.sm),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final canSend = controller.text.trim().isNotEmpty;
                return _RoundButton(
                  tooltip: busy ? 'Stop' : 'Send',
                  icon: busy ? AppIcons.close : AppIcons.send,
                  background: busy ? c.dangerSoft : (canSend ? c.accent : c.grouped),
                  foreground: busy ? c.danger : (canSend ? Colors.white : c.textTertiary),
                  onTap: busy ? onStop : (canSend ? onSend : null),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A 48 px round button that lines up with a one-line text field.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: background,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(dimension: 48, child: Icon(icon, size: 22, color: foreground)),
      ),
    ),
  );
}
