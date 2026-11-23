import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:phone_bridge/phone_bridge.dart';

import '../../core/json.dart';
import '../file_store.dart';

/// The phone productivity steps' effects: `calendar`, `contacts`, `ask`,
/// `listen`, `soundMode`, `clock` and `photo`, done with the phone's own apps
/// through [PhoneBridge]. Each answers with data, or `{error}`.
class PhoneProductivity {
  PhoneProductivity({required this.phone, required this.dataDir, this.interactive = true, this.askPoll});

  final PhoneBridge phone;
  final Directory dataDir;

  /// False in the background service: permissions can't be asked for there.
  final bool interactive;

  /// How often Ask Me looks for an answer; tests make it quick.
  final Duration? askPoll;

  Map<String, Future<JsonMap> Function(JsonMap effect)> get handlers => {
    'calendar': calendar,
    'contacts': contacts,
    'ask': ask,
    'listen': listen,
    'soundMode': soundMode,
    'clock': clock,
    'photo': photo,
  };

  FileStore get _files => FileStore(dataDir);

  /// The bridge's answer as data, or `{error}`.
  static JsonMap? _error(Object? answer) {
    if (answer is Map && answer['error'] is String) return {'error': answer['error']};
    return null;
  }

  Future<String?> _allowed(String name, String what) async {
    if (await phone.ensurePermissions([name])) return null;
    return interactive
        ? 'FlowDroid may not use your $what: allow it when Android asks, or in Settings → Phone access'
        : 'FlowDroid may not use your $what yet: open FlowDroid and allow it in Settings → Phone access';
  }

  // ---------------------------------------------------------------- calendar

  Future<JsonMap> calendar(JsonMap effect) async {
    final denied = await _allowed('calendar', 'calendar');
    if (denied != null) return {'error': denied};
    final operation = asString(effect['operation'], 'list');
    try {
      if (operation == 'create') {
        final results = <Object?>[];
        for (final e in asMapList(effect['events'])) {
          final event = newEvent(e);
          final answer = await phone.calendarCreate(event);
          if (_error(answer) case final error?) return error;
          results.add({'id': '$answer', 'title': event['title'], 'start': asString(e['start'])});
        }
        return {'results': results};
      }
      final (from, to) = range(asString(effect['from']), asString(effect['to']), DateTime.now());
      final answer = await phone.calendarEvents(from, to, asString(effect['calendar']));
      if (_error(answer) case final error?) return error;
      final events = asMapList(answer);
      if (operation == 'freeSlots') {
        return {
          'slots': freeSlots(
            events,
            from,
            to,
            minutes: asInt(effect['minutes'], 30),
            dayStart: asString(effect['dayStart'], '08:00'),
            dayEnd: asString(effect['dayEnd'], '18:00'),
          ),
        };
      }
      return {'events': events.map(eventItem).toList()};
    } on FormatException catch (e) {
      return {'error': e.message};
    }
  }

  /// [from]..[to] from the node's text: empty `from` is the start of today,
  /// empty `to` the end of `from`'s day.
  static (DateTime, DateTime) range(String fromText, String toText, DateTime now) {
    final from = fromText.trim().isEmpty ? DateTime(now.year, now.month, now.day) : parseWhen(fromText, 'From');
    final to = toText.trim().isEmpty ? DateTime(from.year, from.month, from.day + 1) : parseWhen(toText, 'To');
    if (!to.isAfter(from)) throw const FormatException('“To” must be after “From”');
    return (from, to);
  }

  /// A date (`2026-11-24`) or date and time (`2026-11-24T15:00`, with or without a zone), in local time.
  static DateTime parseWhen(String text, String what) {
    final parsed = DateTime.tryParse(text.trim());
    if (parsed == null) {
      throw FormatException('$what is not a date and time: “${text.trim()}” (use e.g. 2026-11-24T15:00)');
    }
    return parsed.toLocal();
  }

  /// The event the phone should save: epoch ms, all-day events at UTC midnights, a missing end one hour (or day) later.
  static JsonMap newEvent(JsonMap e) {
    final allDay = e['allDay'] == true;
    final start = parseWhen(asString(e['start']), 'Starts');
    final endText = asString(e['end']);
    DateTime end;
    int startMs;
    int endMs;
    if (allDay) {
      final first = DateTime.utc(start.year, start.month, start.day);
      final last = endText.trim().isEmpty ? start : parseWhen(endText, 'Ends');
      startMs = first.millisecondsSinceEpoch;
      // All-day events end at midnight after their last day.
      endMs = DateTime.utc(last.year, last.month, last.day + 1).millisecondsSinceEpoch;
    } else {
      end = endText.trim().isEmpty ? start.add(const Duration(hours: 1)) : parseWhen(endText, 'Ends');
      startMs = start.millisecondsSinceEpoch;
      endMs = end.millisecondsSinceEpoch;
    }
    if (endMs <= startMs) throw const FormatException('the event must end after it starts');
    return {
      'title': asString(e['title']),
      'start': startMs,
      'end': endMs,
      'allDay': allDay,
      'location': asString(e['location']),
      'description': asString(e['description']),
      'calendar': asString(e['calendar']),
    };
  }

  /// An event as workflows see it: times in the phone's zone (`2026-11-24T09:00:00+08:00`), all-day ones as dates.
  static JsonMap eventItem(JsonMap e) {
    final allDay = e['allDay'] == true;
    final start = DateTime.fromMillisecondsSinceEpoch(asInt(e['start']), isUtc: allDay);
    final end = DateTime.fromMillisecondsSinceEpoch(asInt(e['end']), isUtc: allDay);
    return {
      'id': asString(e['id']),
      'title': asString(e['title']),
      'start': allDay ? _date(start) : isoWithOffset(start),
      'end': allDay ? _date(end.subtract(const Duration(days: 1))) : isoWithOffset(end),
      'allDay': allDay,
      'minutes': end.difference(start).inMinutes,
      'location': asString(e['location']),
      'description': asString(e['description']),
      'calendar': asString(e['calendar']),
    };
  }

  /// Free time of at least [minutes] between [from] and [to], within each day's working hours.
  static List<JsonMap> freeSlots(
    List<JsonMap> events,
    DateTime from,
    DateTime to, {
    required int minutes,
    required String dayStart,
    required String dayEnd,
  }) {
    (int, int) hm(String t) {
      final parts = t.split(':');
      return (int.tryParse(parts.first) ?? 0, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
    }

    final (sh, sm) = hm(dayStart);
    final (eh, em) = hm(dayEnd);
    // Busy times, earliest first; all-day and "free" events don't block time.
    final busy = [
      for (final e in events)
        if (e['allDay'] != true && e['busy'] != false)
          (
            DateTime.fromMillisecondsSinceEpoch(asInt(e['start'])),
            DateTime.fromMillisecondsSinceEpoch(asInt(e['end'])),
          ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final slots = <JsonMap>[];
    for (
      var day = DateTime(from.year, from.month, from.day);
      day.isBefore(to);
      day = DateTime(day.year, day.month, day.day + 1)
    ) {
      var cursor = _later(DateTime(day.year, day.month, day.day, sh, sm), from);
      final close = _earlier(DateTime(day.year, day.month, day.day, eh, em), to);
      void add(DateTime until) {
        final length = until.difference(cursor).inMinutes;
        if (length >= max(1, minutes)) {
          slots.add({'start': isoWithOffset(cursor), 'end': isoWithOffset(until), 'minutes': length});
        }
      }

      for (final (start, end) in busy) {
        if (!end.isAfter(cursor) || !start.isBefore(close)) continue;
        if (start.isAfter(cursor)) add(_earlier(start, close));
        cursor = _later(cursor, end);
        if (!cursor.isBefore(close)) break;
      }
      if (cursor.isBefore(close)) add(close);
    }
    return slots;
  }

  static DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
  static DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

  /// `2026-11-24T09:00:00+08:00` in the phone's time zone.
  static String isoWithOffset(DateTime t) {
    final local = t.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    return '${_date(local)}T${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}'
        '$sign${_two(abs.inHours)}:${_two(abs.inMinutes % 60)}';
  }

  /// Events between [from] and [to] for the Calendar Event Trigger (raw, epoch ms);
  /// none without calendar access, which a trigger can't ask for.
  Future<List<JsonMap>> eventsBetween(DateTime from, DateTime to) async {
    try {
      if (!(await phone.access()).calendar) return const [];
    } on Exception {
      return const [];
    }
    final answer = await phone.calendarEvents(from, to, '');
    return _error(answer) == null ? asMapList(answer) : const [];
  }

  // ---------------------------------------------------------------- contacts

  Future<JsonMap> contacts(JsonMap effect) async {
    final denied = await _allowed('contacts', 'contacts');
    if (denied != null) return {'error': denied};
    final results = <Object?>[];
    if (asString(effect['operation']) == 'add') {
      for (final c in asMapList(effect['contacts'])) {
        final answer = await phone.contactsAdd(asString(c['name']), asString(c['phone']), asString(c['email']));
        if (_error(answer) case final error?) return error;
        results.add({'id': '$answer', 'name': asString(c['name'])});
      }
      return {'results': results};
    }
    for (final query in asList(effect['queries'])) {
      final answer = await phone.contactsFind(asString(query), asInt(effect['limit'], 5));
      if (_error(answer) case final error?) return error;
      results.add(asMapList(answer));
    }
    return {'results': results};
  }

  // ---------------------------------------------------------------- Ask Me

  /// Posts the question, then waits for the answer file the notification's buttons write.
  Future<JsonMap> ask(JsonMap effect) async {
    final id = 'ask_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}';
    final file = File('${dataDir.path}/answers/$id.json');
    final posted = await phone.ask(
      id,
      asString(effect['title']),
      asString(effect['question']),
      asList(effect['buttons']).map(asString).toList(),
      effect['reply'] == true,
    );
    if (_error(posted) case final error?) return error;
    final deadline = DateTime.now().add(Duration(milliseconds: asInt(effect['timeoutMs'], 3600000)));
    final poll = askPoll ?? const Duration(milliseconds: 700);
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        try {
          final answer = asMap(jsonDecode(await file.readAsString()));
          return {
            'button': asString(answer['button']),
            'text': asString(answer['text']),
            if (answer['dismissed'] == true) 'dismissed': true,
          };
        } on FormatException {
          return {'error': 'the answer could not be read'};
        } finally {
          await file.delete().catchError((Object _) => file);
        }
      }
      await Future<void>.delayed(poll);
    }
    await phone.askCancel(id);
    return {'timedOut': true};
  }

  // ---------------------------------------------------------------- speech, sound, clock

  Future<JsonMap> listen(JsonMap effect) async {
    final answer = await phone.listen(
      asString(effect['language']),
      asString(effect['prompt']),
      asInt(effect['maxMs'], 30000),
    );
    if (_error(answer) case final error?) return error;
    return asMap(answer);
  }

  Future<JsonMap> soundMode(JsonMap effect) async {
    final answer = await phone.soundMode(asString(effect['mode']));
    if (_error(answer) case final error?) return error;
    return asMap(answer);
  }

  Future<JsonMap> clock(JsonMap effect) async {
    final answer = await phone.clock({
      'operation': asString(effect['operation']),
      'hour': asInt(effect['hour']),
      'minute': asInt(effect['minute']),
      'days': asList(effect['days']).map(asString).toList(),
      'seconds': asInt(effect['seconds'], 60),
      'label': asString(effect['label']),
    });
    if (_error(answer) case final error?) {
      return error['error'] == 'no app handles this'
          ? {'error': 'no clock app on this phone takes alarms or timers'}
          : error;
    }
    return asMap(answer);
  }

  // ---------------------------------------------------------------- photos

  Future<JsonMap> photo(JsonMap effect) async {
    final answer = await phone.photo(
      asString(effect['source'], 'camera'),
      multiple: effect['multiple'] == true,
      pages: asInt(effect['pages'], 5),
      pdf: effect['pdf'] == true,
    );
    if (_error(answer) case final error?) return error;
    final map = asMap(answer);
    final files = _files;
    final refs = <JsonMap>[
      for (final path in asList(map['files']).map(asString)) await files.refOf(File('${files.root.path}/$path')),
    ];
    final pdf = asString(map['pdf']);
    return {
      'files': refs,
      if (pdf.isNotEmpty) 'pdf': await files.refOf(File('${files.root.path}/$pdf')),
      if (map['cancelled'] == true) 'cancelled': true,
    };
  }
}
