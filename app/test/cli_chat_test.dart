import 'dart:convert';

import 'package:flowdroid/runtime/cli_chat.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Claude Code reply', () {
    test('takes the text and the model it used', () {
      final out = jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': ' Hello Ann \n',
        'modelUsage': {
          'claude-opus-5-5': {'inputTokens': 3},
        },
      });
      expect(CliChat.parseResult('warming up\n$out\n', '', 0), {
        'text': 'Hello Ann',
        'model': 'claude-opus-5-5',
        'stopReason': 'success',
      });
    });

    test('reports Claude Code errors and missing output', () {
      final failed = jsonEncode({
        'type': 'result',
        'subtype': 'error_during_execution',
        'is_error': true,
        'result': '',
      });
      expect(CliChat.parseResult(failed, '', 1), {'error': 'stopped with an error (error_during_execution)'});
      expect(CliChat.parseResult('', 'Invalid API key · Please run /login\n', 1), {
        'error': 'Invalid API key · Please run /login',
      });
      expect(CliChat.parseResult('', '', 2), {'error': 'Claude Code stopped (exit 2)'});
    });

    test('reports the step limit, and an agent run’s session, steps and cost', () {
      final limit = jsonEncode({'type': 'result', 'subtype': 'error_max_turns', 'is_error': false, 'num_turns': 5});
      expect(CliChat.parseResult(limit, '', 0), {'error': 'stopped at the step limit without a final answer'});
      final done = jsonEncode({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': 'Tidied 3 files.',
        'session_id': 'abc-123',
        'num_turns': 4,
        'total_cost_usd': 0.12,
        'modelUsage': {
          'claude-sonnet-5-5': {'inputTokens': 9},
        },
      });
      expect(CliChat.parseResult(done, '', 0), {
        'text': 'Tidied 3 files.',
        'model': 'claude-sonnet-5-5',
        'sessionId': 'abc-123',
        'steps': 4,
        'stopReason': 'success',
        'costUsd': 0.12,
      });
    });
  });

  group('Claude Code command', () {
    test('a chat only reads, with its own system prompt', () {
      final command = CliChat.command({'prompt': 'hi', 'system': 'Be brief.', 'model': 'opus'}, '/tmp/c1');
      expect(
        command,
        "mkdir -p '/tmp/c1' && cd '/tmp/c1' && claude -p \"\$(cat /tmp/c1/prompt.txt)\" --output-format json "
        "--allowedTools Read --strict-mcp-config --system-prompt \"\$(cat /tmp/c1/system.txt)\" --model 'opus'",
      );
    });

    test('an agent works in its folder with the tools, MCP servers and turns it was given', () {
      final chat = {
        'mode': 'agent',
        'prompt': 'tidy',
        'system': 'Careful.',
        'model': '',
        'folder': '/root/files/notes',
        'tools': ['Read', 'Edit', 'mcp__docs'],
        'mcpServers': {
          'docs': {'type': 'http', 'url': 'https://d/mcp'},
        },
        'maxTurns': 7,
      };
      expect(
        CliChat.command(chat, '/tmp/c2', resume: "s'1"),
        "mkdir -p '/root/files/notes' && cd '/root/files/notes' && claude -p \"\$(cat /tmp/c2/prompt.txt)\" "
        "--output-format json --allowedTools 'Read,Edit,mcp__docs' --max-turns 7 --mcp-config /tmp/c2/mcp.json "
        '--strict-mcp-config --append-system-prompt "\$(cat /tmp/c2/system.txt)" '
        r"--resume 's'\''1'",
      );
      final bare = CliChat.command({
        'mode': 'agent',
        'prompt': 'x',
        'folder': '/w',
        'tools': <String>[],
        'maxTurns': 1,
      }, '/tmp/c3');
      expect(bare, contains("--allowedTools '' --max-turns 1 --strict-mcp-config"));
      expect(bare, isNot(contains('--mcp-config')));
    });
  });
}
