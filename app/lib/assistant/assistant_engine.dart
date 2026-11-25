import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../data/credentials.dart';
import 'workflow_tools.dart';

/// Something the assistant did, shown in the chat as it happens.
sealed class AssistantEvent {
  const AssistantEvent();
}

/// Text the assistant wrote to the person.
class AssistantText extends AssistantEvent {
  const AssistantText(this.text);

  final String text;
}

/// A tool it used: a short line such as “Added “Get weather””.
class AssistantAction extends AssistantEvent {
  const AssistantAction(this.summary, {this.isError = false});

  final String summary;
  final bool isError;
}

/// Why the turn could not go on.
class AssistantFailure extends AssistantEvent {
  const AssistantFailure(this.message);

  final String message;
}

class AssistantException implements Exception {
  const AssistantException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef Emit = void Function(AssistantEvent event);

/// A stream fed by [work]; an unexpected error ends it as a failure.
Stream<AssistantEvent> streamOf(Future<void> Function(Emit emit) work) {
  final out = StreamController<AssistantEvent>();
  unawaited(() async {
    try {
      await work(out.add);
    } on Object catch (e) {
      out.add(AssistantFailure('$e'));
    } finally {
      await out.close();
    }
  }());
  return out.stream;
}

/// One conversation with some AI: it keeps the history and runs tool calls
/// with [WorkflowTools] until the reply is done.
abstract class AssistantEngine {
  /// Shown in the chat header, e.g. “Claude API · claude-opus-5-5”.
  String get label;

  /// Sends [message] and reports what happens until the reply is finished.
  Stream<AssistantEvent> send(String message, WorkflowTools tools);

  /// Stops the reply in progress.
  void cancel();

  /// Forgets the conversation.
  void reset();
}

/// What the assistant knows about FlowDroid; the same for every engine.
const assistantInstructions = '''
You are the assistant inside FlowDroid, an Android app for automations: workflows of steps, like n8n, that run on the phone.
You plan, build, edit, explain and debug the workflow open in the editor, using the FlowDroid tools.

How workflows work
- A workflow starts at a trigger step (manual, schedule, webhook, SMS, notification, share, …) and passes items (JSON objects) from step to step along connections.
- Each step gets the items from the steps connected to its input and outputs items on one or more outputs (If: output 0 true, 1 false; Switch: one per rule).
- Parameters can hold expressions in double braces: {{ \$json.field }} is the current item, {{ \$node["Step name"].json.field }} the first item another step output, plus \$items, \$index, \$vars.name, \$now, \$workflow.name. Expressions support operators, ternary, ??, string and list methods, Math and JSON.
- A credential parameter takes the name of a saved credential. Never invent one: if none fits, tell the person to add it in Settings → Credentials.

How to work
- Start with get_workflow. Before using a step type, read it with describe_node_types so every parameter key and shape is right. Use list_node_types to find types.
- Build with add_node (with "after" to connect it), connect, update_node and remove_node. Give steps short names that say what they do. The layout is done for you.
- To plan something bigger, say the plan in a few lines first, then build it.
- To debug, read get_last_run (or run it) and look at the failing step’s error and input; fix the parameters, then check the fix with run_step.
- Running really does things (messages, calls, phone actions); the person approves each run. Only run when it helps, and say what it will do.
- Websites: never ask the person for selectors or page details. Use browse to open the site, look around and
  find each button, field and value; then build a Browser step (browser.run) whose script uses the "target" each
  element shows (or text="Label"), and test it with run_step. Script lines: open URL, click TARGET,
  type TARGET TEXT, press Enter, wait SECONDS, wait for TARGET, extract NAME SELECTOR (extract all NAME SELECTOR
  for lists, add @attr for an attribute), scroll [TARGET], back, screenshot [NAME]. Steps wait for elements by
  themselves. Leave "Show the browser" off and fast mode on unless the person wants to watch.
- Browser scripts that work every time, on any site:
  - Wait for what you need (wait for TARGET), never a fixed "wait N": fixed pauses slow every run and still
    fail when the site is slow.
  - To send in a chat or comment box: type into it, then click its send button if browse shows one
    (press Enter only when there is none).
  - End every script that sends, posts, saves or submits with a check that it worked, such as
    wait for text="the message you sent". Then a run that did nothing fails instead of reporting success.
  - If browse finds no buttons or fields, it gives a screenshot path: look at the picture if you can read
    files, otherwise browse "read" again after the page has had time to draw.
- When the job changes every time or needs judgement (find the cheapest, answer from what the page says), use
  an AI Agent step with a browser tool and describe the task in words instead of a fixed script.
- If a site needs an account and browse shows a login page, call log_in_to_site: the person logs in once and
  every automation keeps using that login until the site ends it. Never ask for or type passwords.
- Answer briefly and plainly: the person is on a phone. No long code dumps; the canvas shows the result.''';

// ---------------------------------------------------------------------------
// APIs
// ---------------------------------------------------------------------------

/// Talks to an AI provider's API with a saved credential: Anthropic's
/// Messages API, or the OpenAI chat completions API (OpenAI, Gemini, and
/// OpenAI-compatible servers such as Ollama or OpenRouter).
class ApiAssistant extends AssistantEngine {
  ApiAssistant({required this.credentials, required this.credentialName, required this.model, http.Client? client})
    : _client = client ?? http.Client();

  final CredentialStore credentials;
  final String credentialName;
  final String model;
  final http.Client _client;

  /// Messages in the provider's own format, kept exactly as received.
  final _history = <JsonMap>[];
  bool _cancelled = false;
  String _provider = '';

  @override
  String get label =>
      '${switch (_provider) {
        'anthropic' => 'Claude API',
        'openai' => 'OpenAI API',
        'gemini' => 'Gemini API',
        _ => credentialName,
      }} · $model';

  @override
  void cancel() => _cancelled = true;

  @override
  void reset() => _history.clear();

  static const _maxRounds = 40;

  @override
  Stream<AssistantEvent> send(String message, WorkflowTools tools) => streamOf((emit) async {
    _cancelled = false;
    final credential = await credentials.byName(credentialName);
    if (credential == null) {
      emit(AssistantFailure('the credential “$credentialName” is gone: choose another in the assistant settings'));
      return;
    }
    _provider = credential.type;
    final mark = _history.length;
    try {
      if (credential.type == 'anthropic') {
        await _anthropic(message, tools, credential.values['apiKey'] ?? '', emit);
      } else {
        await _openAi(message, tools, credential, emit);
      }
    } on AssistantException catch (e) {
      _rollBack(mark);
      emit(AssistantFailure(e.message));
    } on TimeoutException {
      _rollBack(mark);
      emit(const AssistantFailure('the AI took too long to answer'));
    } on SocketException catch (e) {
      _rollBack(mark);
      emit(AssistantFailure('no connection: ${e.message}'));
    } on http.ClientException catch (e) {
      _rollBack(mark);
      emit(AssistantFailure('no connection: ${e.message}'));
    }
  });

  /// After a failed request the history must still be valid to send again:
  /// drop the unanswered turn.
  void _rollBack(int mark) {
    if (_history.length > mark) _history.removeRange(mark, _history.length);
  }

  // ---- Anthropic Messages API ----

  /// Models that take the effort setting.
  static final _effortModels = RegExp(r'claude-(opus-(5|4-[5-8])|sonnet-(5|4-6)|fable|mythos|haiku-5)');

  /// Models with server-side refusal fallbacks.
  static const _fallbackModels = {
    'claude-fable-5-2',
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  Future<void> _anthropic(String message, WorkflowTools tools, String key, Emit emit) async {
    if (key.isEmpty) throw const AssistantException('the credential has no API key');
    _history.add({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': message},
      ],
    });
    final toolList = [
      for (final t in WorkflowTools.specs) {'name': t.name, 'description': t.description, 'input_schema': t.schema},
    ];
    final fallbacks = _fallbackModels.contains(model);
    for (var round = 0; round < _maxRounds; round++) {
      if (_cancelled) return;
      final body = {
        'model': model,
        'max_tokens': 16000,
        'system': [
          // Tools and instructions stay the same all conversation: cache them.
          {
            'type': 'text',
            'text': assistantInstructions,
            'cache_control': {'type': 'ephemeral'},
          },
        ],
        'tools': toolList,
        'messages': _history,
        if (_effortModels.hasMatch(model)) 'output_config': {'effort': 'high'},
        if (fallbacks) 'fallbacks': 'default',
      };
      final r = await _client
          .post(
            Uri.parse('https://api.anthropic.com/v1/messages'),
            headers: {
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2026-10-21',
              if (fallbacks) 'anthropic-beta': 'server-side-fallback-2026-07-01',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 10));
      if (_cancelled) return;
      if (r.statusCode != 200) throw AssistantException(_apiError(r));
      final reply = asMap(jsonDecode(utf8.decode(r.bodyBytes)));
      final content = asMapList(reply['content']);
      // Kept whole (thinking blocks included) so the next request continues it.
      _history.add({'role': 'assistant', 'content': content});
      for (final block in content) {
        if (block['type'] == 'text' && asString(block['text']).trim().isNotEmpty) {
          emit(AssistantText(asString(block['text']).trim()));
        }
      }
      final stop = asString(reply['stop_reason']);
      if (stop == 'refusal') {
        _history.removeLast();
        emit(const AssistantFailure('Claude declined this request'));
        return;
      }
      final calls = content.where((b) => b['type'] == 'tool_use').toList();
      if (stop == 'max_tokens' && calls.isEmpty) {
        emit(const AssistantFailure('the reply was too long and was cut'));
        return;
      }
      if (calls.isEmpty) return;
      final results = <JsonMap>[];
      for (final call in calls) {
        final outcome = _cancelled
            ? const ToolOutcome('stopped by the person', isError: true)
            : await tools.call(asString(call['name']), asMap(call['input']));
        if (outcome.summary case final s?) emit(AssistantAction(s, isError: outcome.isError));
        results.add({
          'type': 'tool_result',
          'tool_use_id': call['id'],
          'content': outcome.text,
          if (outcome.isError) 'is_error': true,
        });
      }
      // Every result in one message, so parallel calls stay parallel.
      _history.add({'role': 'user', 'content': results});
    }
    emit(const AssistantFailure('stopped after many steps; say “continue” to go on'));
  }

  // ---- OpenAI chat completions (OpenAI, Gemini, compatible servers) ----

  Future<void> _openAi(String message, WorkflowTools tools, Credential credential, Emit emit) async {
    final key = credential.values['apiKey'] ?? '';
    var base = (credential.values['baseUrl'] ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      base = switch (credential.type) {
        'gemini' => 'https://generativelanguage.googleapis.com/v1beta/openai',
        'openai' => 'https://api.openai.com/v1',
        _ => throw const AssistantException('the credential needs a Base URL'),
      };
    }
    final gemini = credential.type == 'gemini';
    _history.add({'role': 'user', 'content': message});
    final toolList = [
      for (final t in WorkflowTools.specs)
        {
          'type': 'function',
          'function': {
            'name': t.name,
            'description': t.description,
            // Gemini's compatible endpoint rejects some JSON Schema keywords.
            'parameters': gemini ? _plainSchema(t.schema) : t.schema,
          },
        },
    ];
    for (var round = 0; round < _maxRounds; round++) {
      if (_cancelled) return;
      final r = await _client
          .post(
            Uri.parse('$base/chat/completions'),
            headers: {'Content-Type': 'application/json', if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'system', 'content': assistantInstructions},
                ..._history,
              ],
              'tools': toolList,
            }),
          )
          .timeout(const Duration(minutes: 10));
      if (_cancelled) return;
      if (r.statusCode != 200) throw AssistantException(_apiError(r));
      final reply = asMap(jsonDecode(utf8.decode(r.bodyBytes)));
      final msg = asMap(asMap(asList(reply['choices']).firstOrNull)['message']);
      if (msg.isEmpty) throw const AssistantException('the AI sent an empty answer');
      final calls = asMapList(msg['tool_calls']);
      _history.add({'role': 'assistant', 'content': msg['content'], if (calls.isNotEmpty) 'tool_calls': calls});
      final text = asString(msg['content']).trim();
      if (text.isNotEmpty) emit(AssistantText(text));
      if (calls.isEmpty) return;
      for (final call in calls) {
        final fn = asMap(call['function']);
        JsonMap args;
        try {
          args = asMap(jsonDecode(asString(fn['arguments'], '{}')));
        } on FormatException {
          args = const {};
        }
        final outcome = _cancelled
            ? const ToolOutcome('stopped by the person', isError: true)
            : await tools.call(asString(fn['name']), args);
        if (outcome.summary case final s?) emit(AssistantAction(s, isError: outcome.isError));
        _history.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': outcome.isError ? 'Error: ${outcome.text}' : outcome.text,
        });
      }
    }
    emit(const AssistantFailure('stopped after many steps; say “continue” to go on'));
  }

  static Object? _plainSchema(Object? schema) {
    if (schema is Map) {
      return {
        for (final MapEntry(:key, :value) in schema.entries)
          if (key != 'additionalProperties') key: _plainSchema(value),
      };
    }
    if (schema is List) return schema.map(_plainSchema).toList();
    return schema;
  }

  static String _apiError(http.Response r) {
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      final err = body is List ? asMap(body.firstOrNull)['error'] : asMap(body)['error'];
      final message = err is Map ? asString(err['message']) : asString(err);
      if (message.isNotEmpty) return 'HTTP ${r.statusCode}: $message';
    } on FormatException {
      // Not JSON.
    }
    return switch (r.statusCode) {
      401 || 403 => 'the API key was refused (HTTP ${r.statusCode})',
      429 => 'too many requests or out of credit (HTTP 429)',
      _ => 'HTTP ${r.statusCode}',
    };
  }
}
