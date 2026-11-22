import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../data/repository.dart';
import 'email_service.dart';
import 'feeds.dart';
import 'runner.dart';

/// Triggers that FlowDroid checks on a timer: Place (every minute), RSS and Email (every N minutes).
/// [tick] runs once a minute from the scheduler's timer.
class TriggerPollers {
  TriggerPollers({required this.repository, required this.runner, required this.feeds, required this.email});

  /// Most posts remembered per feed, to tell new ones from old.
  static const _rememberPosts = 300;

  final Repository repository;
  final WorkflowRunner runner;
  final FeedReader feeds;
  final EmailService email;
  bool _busy = false;

  Future<void> tick([DateTime? now]) async {
    if (_busy) return;
    _busy = true;
    try {
      final at = now ?? DateTime.now();
      final active = (await repository.workflows()).where((w) => w.active).toList();
      final places = [
        for (final wf in active)
          for (final t in wf.nodesOfType('trigger.place')) (wf, t),
      ];
      if (places.isNotEmpty) await _checkPlaces(places);
      for (final wf in active) {
        for (final t in wf.nodesOfType('trigger.rss')) {
          await _guard('RSS', () => _checkFeed(wf, t, at));
        }
        for (final t in wf.nodesOfType('trigger.email')) {
          await _guard('Email', () => _checkMail(wf, t, at));
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _guard(String what, Future<void> Function() check) async {
    try {
      await check();
    } on Exception catch (e) {
      debugPrint('$what trigger: $e');
    }
  }

  /// True when [trigger] is due (its "every N minutes" has passed); records the check.
  Future<bool> _due(String key, WorkflowNode trigger, DateTime now, int defaultMinutes) async {
    final minutes = asInt(trigger.params['minutes'], defaultMinutes).clamp(1, 24 * 60);
    final state = await repository.readState(key) ?? const {};
    final last = DateTime.tryParse(asString(state['checkedAt']));
    return last == null || now.difference(last).inSeconds >= minutes * 60 - 5;
  }

  Future<void> _checkFeed(Workflow wf, WorkflowNode trigger, DateTime now) async {
    final key = 'rss.${wf.id}.${trigger.id}';
    if (!await _due(key, trigger, now, 15)) return;
    final url = asString(trigger.params['url']);
    final state = await repository.readState(key) ?? const {};
    final seen = asList(state['seen']).map(asString).toSet();
    final posts = url.isEmpty ? const <JsonMap>[] : await feeds.read(url);
    final firstCheck = state['seen'] == null;
    final fresh = posts.where((p) => !seen.contains(asString(p['id']))).toList();
    final remembered = [...posts.map((p) => asString(p['id'])), ...seen].take(_rememberPosts).toList();
    await repository.writeState(key, {'checkedAt': now.toIso8601String(), 'seen': remembered});
    // The first check only learns what is already there.
    if (firstCheck) return;
    for (final post in fresh.reversed) {
      await runner.run(wf, triggerNodeId: trigger.id, mode: TriggerMode.rss, items: [post]);
    }
  }

  Future<void> _checkMail(Workflow wf, WorkflowNode trigger, DateTime now) async {
    final key = 'email.${wf.id}.${trigger.id}';
    if (!await _due(key, trigger, now, 5)) return;
    final state = await repository.readState(key) ?? const {};
    final credential = asString(trigger.params['credential']);
    if (credential.isEmpty) return;
    final (messages, lastUid) = await email.newMessages(
      credential,
      asString(trigger.params['mailbox'], 'INBOX'),
      asInt(state['lastUid']),
    );
    await repository.writeState(key, {'checkedAt': now.toIso8601String(), 'lastUid': lastUid});
    for (final message in messages) {
      await runner.run(wf, triggerNodeId: trigger.id, mode: TriggerMode.email, items: [message]);
    }
  }

  /// One position fix for all Place triggers; each fires when its inside/outside state flips.
  Future<void> _checkPlaces(List<(Workflow, WorkflowNode)> places) async {
    final permission = await Geolocator.checkPermission();
    if (permission != LocationPermission.always && permission != LocationPermission.whileInUse) return;
    final Position here;
    try {
      here = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 30)),
      );
    } on Exception catch (e) {
      debugPrint('Place trigger: no position ($e)');
      return;
    }
    for (final (wf, trigger) in places) {
      final p = trigger.params;
      final distance = Geolocator.distanceBetween(
        here.latitude,
        here.longitude,
        asDouble(p['latitude']),
        asDouble(p['longitude']),
      );
      final inside = distance <= asDouble(p['radius'], 200);
      final key = 'place.${wf.id}.${trigger.id}';
      final before = (await repository.readState(key))?['inside'];
      await repository.writeState(key, {'inside': inside});
      // The first fix only learns where the phone is.
      if (before is! bool || before == inside) continue;
      final event = inside ? 'enter' : 'leave';
      if (asString(p['event'], 'enter') != event) continue;
      await runner.run(
        wf,
        triggerNodeId: trigger.id,
        mode: TriggerMode.place,
        items: [
          {'event': event, 'latitude': here.latitude, 'longitude': here.longitude, 'distance': distance.round()},
        ],
      );
    }
  }
}
