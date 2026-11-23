import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../core/json.dart';
import '../runtime/linux/linux_runtime.dart';
import 'assistant_engine.dart';
import 'workflow_tools.dart';

/// The coding agents that can run in FlowDroid's Ubuntu with the person's own account.
enum CliAgentKind {
  claudeCode('Claude Code', 'claude'),
  codex('Codex', 'codex');

  const CliAgentKind(this.label, this.command);

  final String label;
  final String command;

  /// Typed into the terminal: installs the agent, then starts its sign-in.
  String get installCommand => switch (this) {
    claudeCode =>
      'apt-get update && apt-get install -y curl ca-certificates && curl -fsSL https://claude.ai/install.sh | bash && '
          'export PATH="\$HOME/.local/bin:\$PATH" && claude',
    codex =>
      'apt-get update && apt-get install -y curl ca-certificates nodejs npm && npm install -g @openai/codex && '
          'codex login --device-auth',
  };

  /// Typed into the terminal to sign in again.
  String get signInCommand => switch (this) {
    claudeCode => 'export PATH="\$HOME/.local/bin:\$PATH" && claude',
    codex => 'codex login --device-auth',
  };
}

const _path = r'export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"';

/// Whether [kind] is installed in Ubuntu.
Future<bool> cliAgentInstalled(LinuxRuntime linux, CliAgentKind kind) async {
  if (!await linux.ubuntuInstalled) return false;
  final r = await linux.run('$_path; command -v ${kind.command}', target: LinuxTarget.ubuntu);
  return r.error == null && r.exitCode == 0 && r.stdout.trim().isNotEmpty;
}

/// Serves [WorkflowTools] to an agent in Ubuntu over MCP. The agent starts
/// `mcp-bridge.sh` (stdio); the script posts each JSON-RPC line here over
/// localhost with a secret token and prints the answer.
class McpToolServer {
  HttpServer? _server;
  final token = List.generate(32, (_) => Random.secure().nextInt(16).toRadixString(16)).join();

  /// The tools of the reply in progress, and where their actions are shown.
  WorkflowTools? tools;
  Emit? emit;

  Future<String> start() async {
    var server = _server;
    if (server == null) {
      // Bound and listened to once; every later message reuses it (a server can't be listened to twice).
      server = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle, onError: (Object _) {});
    }
    return 'http://127.0.0.1:${server.port}/mcp';
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final res = request.response;
    if (request.method != 'POST' || request.headers.value('authorization') != 'Bearer $token') {
      res.statusCode = HttpStatus.unauthorized;
      await res.close();
      return;
    }
    Object? message;
    try {
      message = jsonDecode(await utf8.decodeStream(request));
    } on FormatException {
      message = null;
    }
    final reply = message is Map ? await answer(asMap(message)) : null;
    res.headers.contentType = ContentType.json;
    if (reply != null) res.write(jsonEncode(reply));
    await res.close();
  }

  /// One JSON-RPC message; null for notifications.
  Future<JsonMap?> answer(JsonMap message) async {
    final id = message['id'];
    if (id == null) return null;
    final params = asMap(message['params']);
    JsonMap ok(Object result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    switch (message['method']) {
      case 'initialize':
        return ok({
          'protocolVersion': asString(params['protocolVersion'], '2025-06-18'),
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'flowdroid', 'version': '1.0'},
          'instructions': 'Tools for the FlowDroid workflow open in the editor.',
        });
      case 'ping':
        return ok({});
      case 'tools/list':
        return ok({
          'tools': [
            for (final t in WorkflowTools.specs)
              {'name': t.name, 'description': t.description, 'inputSchema': t.schema},
          ],
        });
      case 'tools/call':
        final tools = this.tools;
        if (tools == null) {
          return ok({
            'content': [
              {'type': 'text', 'text': 'the FlowDroid editor is closed'},
            ],
            'isError': true,
          });
        }
        final outcome = await tools.call(asString(params['name']), asMap(params['arguments']));
        if (outcome.summary case final s?) emit?.call(AssistantAction(s, isError: outcome.isError));
        return ok({
          'content': [
            {'type': 'text', 'text': outcome.text},
          ],
          'isError': outcome.isError,
        });
      default:
        return {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'unknown method ${message['method']}'},
        };
    }
  }
}

/// Bash and curl: stdin lines to the app, answers back to stdout.
const mcpBridgeScript = r'''#!/bin/bash
# FlowDroid's MCP bridge: passes each JSON-RPC message to the app on this phone.
URL="$1"; TOKEN="$2"
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  resp=$(printf '%s' "$line" | curl -s -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' --data-binary @- "$URL")
  [ -n "$resp" ] && printf '%s\n' "$resp"
done
''';

/// Claude Code or Codex in FlowDroid's Ubuntu, signed in with the person's own
/// account, working on the workflow through [McpToolServer].
class CliAssistant extends AssistantEngine {
  CliAssistant({required this.linux, required this.kind, this.model = ''});

  final LinuxRuntime linux;
  final CliAgentKind kind;
  final String model;
  final _mcp = McpToolServer();
  String? _session;
  Completer<void>? _cancel;

  @override
  String get label => '${kind.label} in Ubuntu${model.isEmpty ? '' : ' · $model'}';

  @override
  void cancel() {
    final c = _cancel;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  void reset() {
    _session = null;
    unawaited(_mcp.close());
  }

  String get _dir => '${linux.rootfs.path}/root/.flowdroid';

  @override
  Stream<AssistantEvent> send(String message, WorkflowTools tools) => streamOf((emit) async {
    if (!await linux.ubuntuInstalled) {
      emit(const AssistantFailure('install Ubuntu first: Settings → Terminal'));
      return;
    }
    final url = await _mcp.start();
    _mcp
      ..tools = tools
      ..emit = emit;
    final first = _session == null;
    await Directory(_dir).create(recursive: true);
    await Directory('${linux.rootfs.path}/root/flowdroid-assistant').create(recursive: true);
    await File('$_dir/mcp-bridge.sh').writeAsString(mcpBridgeScript);
    await File('$_dir/prompt.txt')
        .writeAsString(kind == CliAgentKind.codex && first ? '$assistantInstructions\n\n---\n\n$message' : message);
    await File('$_dir/instructions.txt').writeAsString(assistantInstructions);
    final args = ['/root/.flowdroid/mcp-bridge.sh', url, _mcp.token];
    final String command;
    switch (kind) {
      case CliAgentKind.claudeCode:
        await File('$_dir/mcp.json').writeAsString(
          jsonEncode({
            'mcpServers': {
              'flowdroid': {'type': 'stdio', 'command': 'bash', 'args': args},
            },
          }),
        );
        command = [
          'MCP_TOOL_TIMEOUT=900000 claude -p "\$(cat /root/.flowdroid/prompt.txt)"',
          '--output-format stream-json --verbose',
          '--mcp-config /root/.flowdroid/mcp.json --strict-mcp-config',
          '--allowedTools "mcp__flowdroid,WebSearch,WebFetch"',
          '--append-system-prompt "\$(cat /root/.flowdroid/instructions.txt)"',
          if (model.isNotEmpty) '--model ${_quote(model)}',
          if (_session case final s?) '--resume ${_quote(s)}',
        ].join(' ');
      case CliAgentKind.codex:
        command = [
          'codex exec --json --skip-git-repo-check',
          "-c 'mcp_servers.flowdroid.command=\"bash\"'",
          '-c ${_quote('mcp_servers.flowdroid.args=${jsonEncode(args)}')}',
          "-c 'mcp_servers.flowdroid.tool_timeout_sec=900'",
          if (model.isNotEmpty) '-m ${_quote(model)}',
          if (_session case final s?) 'resume ${_quote(s)}',
          '"\$(cat /root/.flowdroid/prompt.txt)"',
        ].join(' ');
    }
    final cancel = _cancel = Completer<void>();
    final lines = _LineSplitter((line) => _event(line, emit));
    final stderr = StringBuffer();
    var spoke = false;
    final r = await linux.run(
      '$_path; cd /root/flowdroid-assistant && $command < /dev/null',
      target: LinuxTarget.ubuntu,
      timeout: const Duration(minutes: 30),
      cancel: cancel.future,
      onOutput: (text, {required isError}) {
        if (isError) {
          if (stderr.length < 4000) stderr.write(text);
        } else {
          spoke = true;
          lines.add(text);
        }
      },
    );
    lines.close();
    _mcp
      ..tools = null
      ..emit = null;
    if (cancel.isCompleted) return;
    if (r.error != null) {
      emit(AssistantFailure(r.error!));
    } else if (r.exitCode == 127) {
      emit(AssistantFailure('${kind.label} is not installed in Ubuntu: open the assistant settings to install it'));
    } else if (r.exitCode != 0 && !_reported) {
      final last = stderr.toString().trim().split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      emit(
        AssistantFailure(
          last ?? (spoke ? '${kind.label} stopped (exit ${r.exitCode})' : '${kind.label} did not start'),
        ),
      );
    }
    _reported = false;
  });

  /// An error was already shown for this reply.
  bool _reported = false;

  void _event(String line, Emit emit) {
    final JsonMap e;
    try {
      e = asMap(jsonDecode(line));
    } on FormatException {
      return;
    }
    if (kind == CliAgentKind.claudeCode) {
      _claudeEvent(e, emit);
    } else {
      _codexEvent(e, emit);
    }
  }

  void _claudeEvent(JsonMap e, Emit emit) {
    if (e['session_id'] case final String id when id.isNotEmpty) _session = id;
    switch (e['type']) {
      case 'assistant':
        for (final block in asMapList(asMap(e['message'])['content'])) {
          if (block['type'] == 'text' && asString(block['text']).trim().isNotEmpty) {
            emit(AssistantText(asString(block['text']).trim()));
          } else if (block['type'] == 'tool_use' && !asString(block['name']).startsWith('mcp__flowdroid')) {
            emit(AssistantAction(_builtinTool(asString(block['name']))));
          }
        }
      case 'result' when e['is_error'] == true:
        _reported = true;
        final text = asString(e['result']).trim();
        emit(AssistantFailure(text.isEmpty ? 'Claude Code stopped with an error (${e['subtype']})' : text));
    }
  }

  static String _builtinTool(String name) => switch (name) {
    'WebSearch' => 'Searched the web',
    'WebFetch' => 'Read a web page',
    _ => 'Used $name',
  };

  void _codexEvent(JsonMap e, Emit emit) {
    if (e['thread_id'] case final String id when id.isNotEmpty) _session = id;
    final item = asMap(e['item']);
    switch (e['type']) {
      case 'item.completed' when item['type'] == 'agent_message':
        final text = asString(item['text']).trim();
        if (text.isNotEmpty) emit(AssistantText(text));
      case 'item.completed' when item['type'] == 'web_search':
        emit(const AssistantAction('Searched the web'));
      case 'item.completed' when item['type'] == 'error':
        emit(AssistantAction(asString(item['message']), isError: true));
      case 'turn.failed':
        _reported = true;
        emit(AssistantFailure(asString(asMap(e['error'])['message'], 'Codex stopped with an error')));
      case 'error':
        _reported = true;
        emit(AssistantFailure(asString(e['message'], 'Codex stopped with an error')));
    }
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}

/// Splits streamed text into lines.
class _LineSplitter {
  _LineSplitter(this.onLine);

  final void Function(String line) onLine;
  final _buffer = StringBuffer();

  void add(String text) {
    _buffer.write(text);
    final all = _buffer.toString();
    final cut = all.lastIndexOf('\n');
    if (cut < 0) return;
    _buffer
      ..clear()
      ..write(all.substring(cut + 1));
    for (final line in all.substring(0, cut).split('\n')) {
      if (line.trim().isNotEmpty) onLine(line.trim());
    }
  }

  void close() {
    final rest = _buffer.toString().trim();
    _buffer.clear();
    if (rest.isNotEmpty) onLine(rest);
  }
}
