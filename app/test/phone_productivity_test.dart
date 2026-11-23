import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/runtime/phone/phone_productivity.dart';
import 'package:flowdroid/runtime/trigger_pollers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_bridge/phone_bridge.dart';

/// A phone that answers from memory instead of Android.
class _FakePhone extends PhoneBridge {
  _FakePhone(this.dataDir);

  final Directory dataDir;
  bool allowed = true;
  final asked = <String>[];
  final created = <Map<String, Object?>>[];
  String? answerButton;
  List<String> photoFiles = const [];

  @override
  Future<bool> ensurePermissions(List<String> names) async => allowed;

  @override
  Future<Object?> calendarEvents(DateTime from, DateTime to, String calendar) async => [
    {
      'id': '1',
      'title': 'Standup',
      'start': DateTime(2026, 11, 24, 9).millisecondsSinceEpoch,
      'end': DateTime(2026, 11, 24, 9, 30).millisecondsSinceEpoch,
    },
  ];

  @override
  Future<Object?> calendarCreate(Map<String, Object?> event) async {
    created.add(event);
    return 77;
  }

  @override
  Future<Object?> ask(String id, String title, String question, List<String> buttons, bool reply) async {
    asked.add(id);
    final button = answerButton;
    if (button != null) {
      // The notification's receiver writes the answer file.
      final file = File('${dataDir.path}/answers/$id.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'button': button, 'text': '', 'dismissed': false}));
    }
    return <String, Object?>{};
  }

  @override
  Future<Object?> askCancel(String id) async => null;

  @override
  Future<Object?> photo(String source, {bool multiple = false, int pages = 5, bool pdf = true}) async {
    for (final path in photoFiles) {
      final f = File('${dataDir.path}/files/$path');
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1, 2, 3]);
    }
    return {'files': photoFiles};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _FakePhone phone;
  late PhoneProductivity p;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('productivity');
    phone = _FakePhone(dir);
    p = PhoneProductivity(phone: phone, dataDir: dir, askPoll: const Duration(milliseconds: 5));
  });
  tearDown(() => dir.delete(recursive: true));

  int ms(int h, [int m = 0]) => DateTime(2026, 11, 24, h, m).millisecondsSinceEpoch;

  group('calendar', () {
    test('free time skips busy, all-day and "free" events, within working hours', () {
      final events = <JsonMap>[
        {'start': ms(9), 'end': ms(10)},
        {'start': ms(9, 30), 'end': ms(11)},
        {'start': ms(13), 'end': ms(13, 20)},
        {'start': ms(15), 'end': ms(16), 'busy': false},
        {'start': ms(0), 'end': ms(23, 59), 'allDay': true},
      ];
      final slots = PhoneProductivity.freeSlots(
        events,
        DateTime(2026, 11, 24),
        DateTime(2026, 11, 25),
        minutes: 30,
        dayStart: '08:00',
        dayEnd: '18:00',
      );
      String hm(Object? iso) => asString(iso).substring(11, 16);
      expect(slots.map((s) => '${hm(s['start'])}-${hm(s['end'])} ${s['minutes']}'), [
        '08:00-09:00 60',
        '11:00-13:00 120',
        '13:20-18:00 280',
      ]);
    });

    test('ranges default to today, and must run forwards', () {
      final now = DateTime(2026, 11, 24, 15, 30);
      expect(PhoneProductivity.range('', '', now), (DateTime(2026, 11, 24), DateTime(2026, 11, 25)));
      expect(PhoneProductivity.range('2026-12-01', '', now), (DateTime(2026, 12, 1), DateTime(2026, 12, 2)));
      expect(() => PhoneProductivity.range('2026-12-02', '2026-12-01', now), throwsFormatException);
      expect(() => PhoneProductivity.range('next tuesday', '', now), throwsFormatException);
    });

    test('new events: an hour by default; all-day events from one UTC midnight to the next', () {
      final timed = PhoneProductivity.newEvent({'title': 'T', 'start': '2026-11-24T15:00'});
      expect(asInt(timed['end']) - asInt(timed['start']), const Duration(hours: 1).inMilliseconds);
      final allDay = PhoneProductivity.newEvent({
        'title': 'Trip',
        'start': '2026-11-24',
        'end': '2026-11-26',
        'allDay': true,
      });
      expect(allDay['start'], DateTime.utc(2026, 11, 24).millisecondsSinceEpoch);
      expect(allDay['end'], DateTime.utc(2026, 11, 27).millisecondsSinceEpoch);
      expect(
        () => PhoneProductivity.newEvent({'start': '2026-11-24T15:00', 'end': '2026-11-24T14:00'}),
        throwsFormatException,
      );
    });

    test('events become items with local times; creating returns their ids', () async {
      final listed = await p.calendar({'operation': 'list', 'from': '', 'to': ''});
      final item = asMapList(listed['events']).single;
      expect(item['title'], 'Standup');
      expect(asString(item['start']), startsWith('2026-11-24T09:00:00'));
      expect(item['minutes'], 30);
      final made = await p.calendar({
        'operation': 'create',
        'events': [
          {'title': 'Dentist', 'start': '2026-11-25T10:00'},
        ],
      });
      expect(made['results'], [
        {'id': '77', 'title': 'Dentist', 'start': '2026-11-25T10:00'},
      ]);
      phone.allowed = false;
      expect(asString((await p.calendar({'operation': 'list'}))['error']), contains('calendar'));
    });
  });

  group('Calendar Event Trigger', () {
    final events = <JsonMap>[
      {'id': '1', 'title': 'Team standup', 'calendar': 'Work', 'start': ms(9), 'end': ms(9, 30)},
      {'id': '2', 'title': 'Lunch', 'calendar': 'Home', 'start': ms(12), 'end': ms(13)},
      {'id': '3', 'title': 'Holiday', 'allDay': true, 'start': ms(0), 'end': ms(23)},
    ];

    test('fires minutes before the start, once, within a grace period', () {
      final params = {'event': 'start', 'minutes': 5};
      List<String> due(DateTime now, [Set<String> fired = const {}]) =>
          TriggerPollers.dueCalendarEvents(events, params, now, fired).map((d) => d.$1).toList();
      expect(due(DateTime(2026, 11, 24, 8, 54)), isEmpty);
      expect(due(DateTime(2026, 11, 24, 8, 55)), ['1@${ms(9)}']);
      expect(due(DateTime(2026, 11, 24, 9, 3)), ['1@${ms(9)}']);
      expect(due(DateTime(2026, 11, 24, 9, 6)), isEmpty);
      expect(due(DateTime(2026, 11, 24, 8, 56), {'1@${ms(9)}'}), isEmpty);
    });

    test('after the end, filtered by calendar and title', () {
      final params = {'event': 'end', 'minutes': 0, 'calendar': 'work', 'contains': 'STANDUP'};
      expect(TriggerPollers.dueCalendarEvents(events, params, DateTime(2026, 11, 24, 9, 31), {}).length, 1);
      expect(TriggerPollers.dueCalendarEvents(events, params, DateTime(2026, 11, 24, 13, 1), {}), isEmpty);
    });
  });

  group('Ask Me', () {
    test('returns the tapped button and cleans up', () async {
      phone.answerButton = 'Approve';
      final answer = await p.ask({
        'question': 'Send?',
        'buttons': ['Approve'],
        'timeoutMs': 5000,
      });
      expect(answer, {'button': 'Approve', 'text': ''});
      expect(Directory('${dir.path}/answers').listSync(), isEmpty);
    });

    test('gives up when nobody answers in time', () async {
      final answer = await p.ask({
        'question': 'Send?',
        'buttons': ['Yes'],
        'timeoutMs': 30,
      });
      expect(answer, {'timedOut': true});
    });
  });

  test('photos come back as file references in FlowDroid’s folder', () async {
    phone.photoFiles = ['photos/1-a.jpg'];
    final r = await p.photo({'source': 'camera'});
    expect(r['files'], [
      {'path': 'photos/1-a.jpg', 'name': '1-a.jpg', 'mimeType': 'image/jpeg', 'size': 3},
    ]);
  });
}
