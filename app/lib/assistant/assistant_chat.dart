import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_services.dart';
import '../core/json.dart';
import 'assistant_engine.dart';
import 'cli_assistant.dart';
import 'workflow_tools.dart';

/// Which AI the assistant uses: an API key, or an agent signed in in Ubuntu.
enum AssistantKind { api, claudeCode, codex }

/// The assistant's settings, saved in `assistant.json`.
class AssistantConfig {
  const AssistantConfig({this.kind = AssistantKind.api, this.credential = '', this.model = '', this.cliModel = ''});

  AssistantConfig.fromJson(JsonMap json)
    : kind = AssistantKind.values.asNameMap()[json['kind']] ?? AssistantKind.api,
      credential = asString(json['credential']),
      model = asString(json['model']),
      cliModel = asString(json['cliModel']);

  final AssistantKind kind;

  /// Name of a saved Anthropic, OpenAI, Gemini or OpenAI-compatible credential.
  final String credential;
  final String model;

  /// Model for Claude Code or Codex; empty uses the agent's own default.
  final String cliModel;

  bool get ready => kind != AssistantKind.api || (credential.isNotEmpty && model.isNotEmpty);

  JsonMap toJson() => {'kind': kind.name, 'credential': credential, 'model': model, 'cliModel': cliModel};

  AssistantConfig copyWith({AssistantKind? kind, String? credential, String? model, String? cliModel}) =>
      AssistantConfig(
        kind: kind ?? this.kind,
        credential: credential ?? this.credential,
        model: model ?? this.model,
        cliModel: cliModel ?? this.cliModel,
      );

  static File _file(Directory dataDir) => File('${dataDir.path}/assistant.json');

  static Future<AssistantConfig> load(Directory dataDir) async {
    try {
      return AssistantConfig.fromJson(asMap(jsonDecode(await _file(dataDir).readAsString())));
    } on Object {
      return const AssistantConfig();
    }
  }

  Future<void> save(Directory dataDir) => _file(dataDir).writeAsString(jsonEncode(toJson()));

  AssistantEngine engine(AppServices services) => switch (kind) {
    AssistantKind.api => ApiAssistant(credentials: services.credentials, credentialName: credential, model: model),
    AssistantKind.claudeCode => CliAssistant(linux: services.linux, kind: CliAgentKind.claudeCode, model: cliModel),
    AssistantKind.codex => CliAssistant(linux: services.linux, kind: CliAgentKind.codex, model: cliModel),
  };

  String get label => switch (kind) {
    AssistantKind.api => model.isEmpty ? 'API' : model,
    AssistantKind.claudeCode => 'Claude Code',
    AssistantKind.codex => 'Codex',
  };
}

enum ChatRole { person, assistant, action, failure }

class ChatEntry {
  const ChatEntry(this.role, this.text, {this.isError = false});

  final ChatRole role;
  final String text;
  final bool isError;
}

/// One workflow's conversation with the assistant. Kept while the app runs,
/// so closing and reopening the panel keeps it.
class AssistantChat extends ChangeNotifier {
  AssistantChat._(this.workflowId);

  static final _open = <String, AssistantChat>{};

  static AssistantChat of(String workflowId) => _open.putIfAbsent(workflowId, () => AssistantChat._(workflowId));

  final String workflowId;
  final entries = <ChatEntry>[];
  AssistantEngine? _engine;
  AssistantConfig? _config;
  bool busy = false;

  /// What the engine is, for the header; null before the first message.
  String? get engineLabel => _engine?.label ?? _config?.label;

  /// Runs in this conversation were approved for the rest of it.
  bool runsApproved = false;

  int _turn = 0;

  /// Uses [config]; a different one starts a new conversation with it.
  void configure(AssistantConfig config, AppServices services) {
    final old = _config;
    if (old != null && jsonEncode(old.toJson()) == jsonEncode(config.toJson())) return;
    _engine?.reset();
    _config = config;
    _engine = config.engine(services);
    if (old != null && entries.isNotEmpty) {
      entries.add(ChatEntry(ChatRole.action, 'Switched to ${_engine!.label}: it starts fresh'));
    }
    notifyListeners();
  }

  WorkflowTools? _tools;

  /// The editor closed: stop the reply, and let no tool touch the closed editor.
  void detach() {
    _tools?.closed = true;
    if (busy) _engine?.cancel();
  }

  Future<void> send(String message, WorkflowTools tools) async {
    final engine = _engine;
    if (engine == null || busy || message.trim().isEmpty) return;
    busy = true;
    _tools = tools;
    tools.group = 'assistant:$workflowId:${_turn++}';
    entries.add(ChatEntry(ChatRole.person, message.trim()));
    notifyListeners();
    try {
      await for (final e in engine.send(message.trim(), tools)) {
        entries.add(switch (e) {
          AssistantText(:final text) => ChatEntry(ChatRole.assistant, text),
          AssistantAction(:final summary, :final isError) => ChatEntry(ChatRole.action, summary, isError: isError),
          AssistantFailure(:final message) => ChatEntry(ChatRole.failure, message),
        });
        notifyListeners();
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void stop() {
    _engine?.cancel();
    entries.add(const ChatEntry(ChatRole.action, 'Stopped'));
    notifyListeners();
  }

  void clear() {
    if (busy) return;
    _engine?.reset();
    entries.clear();
    runsApproved = false;
    notifyListeners();
  }
}
