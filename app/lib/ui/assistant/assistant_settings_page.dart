import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../assistant/assistant_chat.dart';
import '../../assistant/cli_assistant.dart';
import '../../core/param_helpers.dart';
import '../../data/credentials.dart';
import '../credentials/credentials_page.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../terminal/terminal_page.dart';
import '../theme.dart';

/// Credential types the assistant can talk to.
const assistantCredentialTypes = {'anthropic', 'openai', 'gemini', 'openaiCompatible'};

/// Chooses the AI behind the assistant: an API key, or Claude Code or Codex
/// signed in with the person's own account in FlowDroid's Ubuntu.
class AssistantSettingsPage extends StatefulWidget {
  const AssistantSettingsPage({super.key});

  @override
  State<AssistantSettingsPage> createState() => _AssistantSettingsPageState();
}

class _AssistantSettingsPageState extends State<AssistantSettingsPage> {
  AssistantConfig? _config;
  List<Credential> _credentials = const [];
  final _model = TextEditingController();
  final _cliModel = TextEditingController();
  final _installed = <CliAgentKind, bool?>{};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  @override
  void dispose() {
    _model.dispose();
    _cliModel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final services = ServicesScope.of(context);
    final config = await AssistantConfig.load(services.dataDir);
    final all = await services.credentials.all();
    if (!mounted) return;
    setState(() {
      _credentials = all.where((c) => assistantCredentialTypes.contains(c.type)).toList();
      var c = config;
      if (c.credential.isEmpty && _credentials.isNotEmpty) c = c.copyWith(credential: _credentials.first.name);
      if (c.model.isEmpty) c = c.copyWith(model: _defaultModel(c.credential));
      _config = c;
      _model.text = c.model;
      _cliModel.text = c.cliModel;
    });
    unawaited(_checkAgents());
  }

  Future<void> _checkAgents() async {
    final linux = ServicesScope.of(context).linux;
    for (final kind in CliAgentKind.values) {
      final ok = await cliAgentInstalled(linux, kind);
      if (mounted) setState(() => _installed[kind] = ok);
    }
  }

  String _typeOf(String credential) => _credentials.where((c) => c.name == credential).firstOrNull?.type ?? 'anthropic';

  String _defaultModel(String credential) => modelSuggestions[_typeOf(credential)]?.first ?? '';

  Future<void> _set(AssistantConfig config) async {
    setState(() => _config = config);
    await config.save(ServicesScope.of(context).dataDir);
  }

  Future<void> _openTerminal(String command) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => TerminalPage(command: command)));
    unawaited(_checkAgents());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = _config;
    return Scaffold(
      appBar: AppBar(),
      body: config == null
          ? const Center(child: QuietSpinner())
          : ListView(
              padding: const EdgeInsets.only(bottom: Space.xxl),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
                  child: Text('Assistant', style: theme.textTheme.headlineMedium),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
                  child: Text(
                    'Plans, builds, edits and debugs workflows with you. Use an API key, or your own Claude or '
                    'ChatGPT plan through Claude Code or Codex in Ubuntu.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.page),
                  child: PillSwitch<AssistantKind>(
                    value: config.kind,
                    options: const [
                      (value: AssistantKind.api, label: 'API key', icon: null),
                      (value: AssistantKind.claudeCode, label: 'Claude Code', icon: null),
                      (value: AssistantKind.codex, label: 'Codex', icon: null),
                    ],
                    onChanged: (k) => _set(config.copyWith(kind: k)),
                  ),
                ),
                if (config.kind == AssistantKind.api) ..._api(config) else ..._cli(config),
              ],
            ),
    );
  }

  List<Widget> _api(AssistantConfig config) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    if (_credentials.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(Space.page),
          child: Text(
            'Add an Anthropic, OpenAI, Google Gemini or OpenAI-compatible (Ollama, OpenRouter, …) credential first.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.page),
          child: FilledButton.icon(
            icon: const Icon(AppIcons.key),
            label: const Text('Add a credential'),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const CredentialsPage()));
              unawaited(_load());
            },
          ),
        ),
      ];
    }
    final type = _typeOf(config.credential);
    return [
      const SectionLabel('ACCOUNT'),
      GroupedSection(
        children: [
          for (final cred in _credentials)
            ListTile(
              title: Text(cred.name),
              subtitle: (credentialType(cred.type)?.label ?? cred.type) == cred.name
                  ? null
                  : Text(credentialType(cred.type)?.label ?? cred.type),
              trailing: cred.name == config.credential ? Icon(AppIcons.check, color: c.accent) : null,
              onTap: () {
                final model = _typeOf(cred.name) == type ? config.model : _defaultModel(cred.name);
                _model.text = model;
                _set(config.copyWith(credential: cred.name, model: model));
              },
            ),
        ],
      ),
      const SectionLabel('MODEL'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
        child: TextField(
          controller: _model,
          decoration: const InputDecoration(hintText: 'Model name'),
          onChanged: (v) => _set(config.copyWith(model: v.trim())),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final m in modelSuggestions[type] ?? const <String>[])
              ChoiceChip(
                label: Text(m),
                selected: config.model == m,
                onSelected: (_) {
                  _model.text = m;
                  _set(config.copyWith(model: m));
                },
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.page, 0),
        child: Text(
          type == 'openaiCompatible'
              ? 'The model must support tool calling (function calling).'
              : 'Bigger models plan and debug better; each message costs a little on your API account.',
          style: theme.textTheme.bodySmall,
        ),
      ),
    ];
  }

  List<Widget> _cli(AssistantConfig config) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final kind = config.kind == AssistantKind.codex ? CliAgentKind.codex : CliAgentKind.claudeCode;
    final installed = _installed[kind];
    final plan = kind == CliAgentKind.claudeCode ? 'Claude Pro or Max plan (or a Console account)' : 'ChatGPT plan';
    return [
      const SectionLabel('IN UBUNTU'),
      GroupedSection(
        children: [
          ListTile(
            leading: Icon(
              installed == true ? AppIcons.checkCircle : AppIcons.warning,
              color: installed == true ? c.success : c.textTertiary,
            ),
            title: Text(kind.label),
            subtitle: Text(switch (installed) {
              null => 'Checking…',
              true => 'Installed',
              false => 'Not installed yet',
            }),
            trailing: installed == null ? const QuietSpinner(size: 18) : null,
          ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.page, 0),
        child: Text(
          'Signs in with your $plan. Installing opens the terminal: follow the sign-in steps there '
          '(open the link, paste the code), then come back.',
          style: theme.textTheme.bodySmall,
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.page, Space.lg, Space.page, 0),
        child: Wrap(
          spacing: Space.md,
          runSpacing: Space.md,
          children: [
            FilledButton.icon(
              icon: const Icon(AppIcons.download),
              label: Text(installed == true ? 'Reinstall' : 'Install and sign in'),
              onPressed: () => _openTerminal(kind.installCommand),
            ),
            if (installed == true)
              OutlinedButton.icon(
                icon: const Icon(AppIcons.key),
                label: const Text('Sign in'),
                onPressed: () => _openTerminal(kind.signInCommand),
              ),
          ],
        ),
      ),
      const SectionLabel('MODEL (OPTIONAL)'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
        child: TextField(
          controller: _cliModel,
          decoration: InputDecoration(
            hintText: kind == CliAgentKind.claudeCode
                ? 'e.g. opus, sonnet (empty = its default)'
                : 'e.g. gpt-5 (empty = its default)',
          ),
          onChanged: (v) => _set(config.copyWith(cliModel: v.trim())),
        ),
      ),
    ];
  }
}
