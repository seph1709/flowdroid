import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../core/workflow.dart';
import '../data/credentials.dart';
import '../data/execution_record.dart';
import '../data/repository.dart';
import 'credential_resolver.dart';
import 'runner.dart';

/// Long-polls Telegram for every bot that an active Telegram Trigger uses,
/// and runs the matching workflows once per incoming message.
class TelegramPoller {
  TelegramPoller({required this.repository, required this.runner, required this.credentials, http.Client? client})
    : _client = client ?? http.Client();

  static const _pollSeconds = 25;
  static const _idle = Duration(seconds: 30);
  static const _backoff = Duration(seconds: 15);

  final Repository repository;
  final WorkflowRunner runner;
  final CredentialStore credentials;
  final http.Client _client;
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() => _running = false;

  Future<void> _loop() async {
    while (_running) {
      final targets = await _targets();
      if (targets.isEmpty) {
        await Future<void>.delayed(_idle);
        continue;
      }
      await Future.wait(targets.entries.map((e) => _poll(e.key, e.value)));
    }
  }

  /// Active Telegram triggers, grouped by the bot credential they use.
  Future<Map<String, List<(Workflow, WorkflowNode)>>> _targets() async {
    final out = <String, List<(Workflow, WorkflowNode)>>{};
    for (final wf in (await repository.workflows()).where((w) => w.active)) {
      for (final trigger in wf.nodesOfType('trigger.telegram')) {
        final name = asString(trigger.params['credential']);
        if (name.isNotEmpty) out.putIfAbsent(name, () => []).add((wf, trigger));
      }
    }
    return out;
  }

  Future<void> _poll(String credentialName, List<(Workflow, WorkflowNode)> targets) async {
    final token = (await credentials.byName(credentialName))?.values['botToken'] ?? '';
    if (token.isEmpty) {
      await Future<void>.delayed(_idle);
      return;
    }
    final stateKey = 'telegram.$credentialName';
    var offset = asInt((await repository.readState(stateKey))?['offset']);
    try {
      final uri = Uri.parse(
        'https://api.telegram.org/bot$token/getUpdates?timeout=$_pollSeconds&offset=$offset'
        '&allowed_updates=${Uri.encodeComponent('["message"]')}',
      );
      final response = await _client.get(uri).timeout(const Duration(seconds: _pollSeconds + 10));
      final body = asMap(jsonDecode(response.body));
      if (body['ok'] != true) throw Exception(asString(body['description'], 'Telegram error ${response.statusCode}'));
      for (final update in asMapList(body['result'])) {
        offset = asInt(update['update_id']) + 1;
        final message = asMap(update['message']);
        if (message.isEmpty) continue;
        final chatId = asMap(message['chat'])['id']?.toString() ?? '';
        for (final (wf, trigger) in targets) {
          final only = asString(trigger.params['chatId']);
          if (only.isNotEmpty && !only.contains('{{') && only != chatId) continue;
          await runner.run(wf, triggerNodeId: trigger.id, mode: TriggerMode.telegram, items: [message]);
        }
      }
      await repository.writeState(stateKey, {'offset': offset});
    } on Exception catch (e) {
      debugPrint('Telegram polling ($credentialName): ${scrub(e.toString(), [token])}');
      await Future<void>.delayed(_backoff);
    }
  }
}
