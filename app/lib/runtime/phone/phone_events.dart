import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:phone_bridge/phone_bridge.dart';

import '../../core/json.dart';
import '../../core/workflow.dart';
import '../../data/execution_record.dart';
import '../../data/repository.dart';
import '../runner.dart';

/// Turns phone events (SMS, notifications, power/Wi-Fi/screen changes, boot,
/// the Quick Settings tile) into runs of the workflows whose triggers match.
///
/// Android code saves each event as a small JSON file; this polls the folder,
/// so events that arrive while FlowDroid starts are not lost.
class PhoneEvents {
  PhoneEvents({required this.dataDir, required this.repository, required this.runner, this.bridge, this.onTick});

  /// Runs due schedules when the wake-up alarm fires (a `tick` event).
  final Future<void> Function()? onTick;

  static const _interval = Duration(seconds: 2);

  /// Events older than this when first seen are dropped (the phone was off, or FlowDroid stopped).
  static const _maxAge = Duration(hours: 1);

  final Directory dataDir;
  final Repository repository;
  final WorkflowRunner runner;
  final PhoneBridge? bridge;
  Timer? _timer;
  bool _busy = false;

  Directory get _dir => Directory('${dataDir.path}/events');

  bool get isRunning => _timer != null;

  void start() {
    if (_timer != null) return;
    unawaited(bridge?.watchPhoneEvents());
    _timer = Timer.periodic(_interval, (_) => unawaited(poll()));
    unawaited(poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Handles every waiting event once, oldest first.
  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      await _dir.create(recursive: true);
      await File('${_dir.path}/.alive').writeAsString('');
      final files = await _dir.list().where((e) => e is File && e.path.endsWith('.json')).cast<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        JsonMap event;
        try {
          event = asMap(jsonDecode(await file.readAsString()));
        } on FormatException {
          event = const {};
        }
        await file.delete().catchError((Object _) => file);
        final at = DateTime.fromMillisecondsSinceEpoch(asInt(event['at']));
        if (DateTime.now().difference(at) > _maxAge) continue;
        await dispatch(event);
      }
    } on FileSystemException catch (e) {
      debugPrint('Phone events: $e');
    } finally {
      _busy = false;
    }
  }

  /// Runs each active workflow whose trigger matches [event].
  Future<void> dispatch(JsonMap event) async {
    final type = asString(event['type']);
    if (type == 'tick') {
      await onTick?.call();
      return;
    }
    final (triggerType, mode) = switch (type) {
      'sms' => ('trigger.sms', TriggerMode.sms),
      'notification' => ('trigger.notification', TriggerMode.notification),
      'phone' => ('trigger.phone', TriggerMode.phone),
      'tile' => ('trigger.tile', TriggerMode.tile),
      _ => ('', TriggerMode.manual),
    };
    if (triggerType.isEmpty) return;
    final item = {...event}..remove('type');
    for (final wf in (await repository.workflows()).where((w) => w.active)) {
      for (final trigger in wf.nodesOfType(triggerType)) {
        if (!matches(trigger, event)) continue;
        await runner.run(wf, triggerNodeId: trigger.id, mode: mode, items: [item]);
      }
    }
  }

  /// Whether [trigger]'s filters accept [event]. Filters are plain text; `{{ }}` filters accept everything.
  static bool matches(WorkflowNode trigger, JsonMap event) {
    String param(String key) {
      final v = asString(trigger.params[key]).trim();
      return v.contains('{{') ? '' : v;
    }

    bool containsText(String haystack, String needle) =>
        needle.isEmpty || haystack.toLowerCase().contains(needle.toLowerCase());
    switch (trigger.type) {
      case 'trigger.sms':
        final from = param('from');
        final digits = from.replaceAll(RegExp(r'[^0-9]'), '');
        final sender = asString(event['from']);
        final fromOk =
            from.isEmpty ||
            (digits.isNotEmpty
                ? sender.replaceAll(RegExp(r'[^0-9]'), '').contains(digits)
                : containsText(sender, from));
        return fromOk && containsText(asString(event['text']), param('contains'));
      case 'trigger.notification':
        final app = param('app');
        final appOk = containsText(asString(event['app']), app) || containsText(asString(event['package']), app);
        final text = '${asString(event['title'])}\n${asString(event['text'])}';
        return appOk && containsText(text, param('contains'));
      case 'trigger.phone':
        return asString(trigger.params['event'], 'powerConnected') == asString(event['event']);
      default:
        return true;
    }
  }
}
