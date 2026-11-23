import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../core/json.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../data/repository.dart';
import 'email_service.dart';
import 'feeds.dart';
import 'phone/phone_productivity.dart';
import 'runner.dart';

/// Raw calendar events (epoch ms) between two times, from the phone.
typedef CalendarReader = Future<List<JsonMap>> Function(DateTime from, DateTime to);

/// Triggers that FlowDroid checks on a timer: Place and Calendar Event (every
/// minute), RSS and Email (every N minutes). [tick] runs once a minute from the scheduler's timer.
class TriggerPollers {
  TriggerPollers({
    required this.repository,
    required this.runner,
    required this.feeds,
    required this.email,
    this.calendar,
  });

  /// How late a Calendar Event trigger may still fire (the phone may tick late while asleep).
  static const calendarGrace = Duration(minutes: 10);

  /// Most posts remembered per feed, to tell new ones from old.
  static const _rememberPosts = 300;

  final Repository repository;
  final WorkflowRunner runner;
  final FeedReader feeds;
  final EmailService email;

  /// The phone's calendar; null where there is none (tests, other platforms).
  final CalendarReader? calendar;
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
      final meetings = [
        for (final wf in active)
          for (final t in wf.nodesOfType('trigger.calendar')) (wf, t),
      ];
      if (meetings.isNotEmpty) await _guard('Calendar', () => _checkCalendar(meetings, at));
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

  /// One calendar read for all Calendar Event triggers; each event fires once per trigger.
  Future<void> _checkCalendar(List<(Workflow, WorkflowNode)> triggers, DateTime now) async {
    final read = calendar;
    if (read == null) return;
    final events = await read(now.subtract(const Duration(days: 1)), now.add(const Duration(days: 1)));
    for (final (wf, trigger) in triggers) {
      final key = 'calendar.${wf.id}.${trigger.id}';
      final state = await repository.readState(key) ?? const {};
      final fired = asList(state['fired']).map(asString).toList();
      final due = dueCalendarEvents(events, trigger.params, now, fired.toSet());
      if (due.isEmpty) continue;
      await repository.writeState(key, {
        'fired': [...due.map((d) => d.$1), ...fired].take(_rememberPosts).toList(),
      });
      for (final (_, event) in due) {
        await runner.run(
          wf,
          triggerNodeId: trigger.id,
          mode: TriggerMode.calendar,
          items: [PhoneProductivity.eventItem(event)],
        );
      }
    }
  }

  /// The events a Calendar Event trigger with [params] fires for at [now]: its
  /// moment (start − minutes, or end + minutes) has come within the last
  /// [calendarGrace], and it didn't fire yet. Each comes with its key for [fired].
  static List<(String, JsonMap)> dueCalendarEvents(
    List<JsonMap> events,
    JsonMap params,
    DateTime now,
    Set<String> fired,
  ) {
    final atEnd = asString(params['event'], 'start') == 'end';
    final minutes = asDouble(params['minutes'], 5);
    final calendar = asString(params['calendar']).trim().toLowerCase();
    final contains = asString(params['contains']).trim().toLowerCase();
    final due = <(String, JsonMap)>[];
    for (final e in events) {
      // All-day events have no moment to come before or after.
      if (e['allDay'] == true) continue;
      if (calendar.isNotEmpty && !asString(e['calendar']).toLowerCase().contains(calendar)) continue;
      if (contains.isNotEmpty && !asString(e['title']).toLowerCase().contains(contains)) continue;
      final edge = DateTime.fromMillisecondsSinceEpoch(asInt(e[atEnd ? 'end' : 'start']));
      final at = edge.add(Duration(seconds: ((atEnd ? minutes : -minutes) * 60).round()));
      if (at.isAfter(now) || now.difference(at) > calendarGrace) continue;
      final key = '${asString(e['id'])}@${asInt(e['start'])}';
      if (!fired.contains(key)) due.add((key, e));
    }
    return due;
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
