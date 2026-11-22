/// Small helpers that spare users from typing what they can't know by heart:
/// IDs inside links, cron syntax, model names, ISO dates.
library;

/// Which ID a pasted link should be reduced to.
enum IdKind { sheet, driveFolder, driveFile, notionDatabase, airtableBase, airtableTable }

/// The ID inside [text] when it is a link (or text) that contains one; null otherwise.
String? idFromLink(IdKind kind, String text) {
  final t = text.trim();
  if (t.isEmpty || t.contains('{{')) return null;
  RegExpMatch? m(String pattern) => RegExp(pattern).firstMatch(t);
  final id = switch (kind) {
    IdKind.sheet => m(r'/spreadsheets/d/([A-Za-z0-9_-]{20,})')?[1],
    IdKind.driveFolder => m(r'/folders/([A-Za-z0-9_-]{10,})')?[1] ?? m(r'[?&]id=([A-Za-z0-9_-]{10,})')?[1],
    IdKind.driveFile =>
      m(r'/(?:file|document|spreadsheets|presentation)/d/([A-Za-z0-9_-]{20,})')?[1] ??
          m(r'[?&]id=([A-Za-z0-9_-]{10,})')?[1],
    // Notion links end in the 32-hex ID, optionally after the page title and before `?v=`.
    IdKind.notionDatabase when t.contains('notion.') => m(r'([0-9a-f]{32})(?:[?#]|$)')?[1],
    IdKind.notionDatabase => null,
    IdKind.airtableBase => m(r'\b(app[A-Za-z0-9]{14})\b')?[1],
    IdKind.airtableTable => m(r'\b(tbl[A-Za-z0-9]{14})\b')?[1],
  };
  return id == null || id == t ? null : id;
}

/// A ready-made schedule.
typedef CronPreset = ({String label, String cron});

const cronPresets = <CronPreset>[
  (label: 'Every 5 minutes', cron: '*/5 * * * *'),
  (label: 'Every hour', cron: '0 * * * *'),
  (label: 'Every day at 9:00', cron: '0 9 * * *'),
  (label: 'Weekdays at 8:00', cron: '0 8 * * 1-5'),
  (label: 'Every Monday at 9:00', cron: '0 9 * * 1'),
  (label: 'First of the month', cron: '0 9 1 * *'),
];

const _days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _two(int n) => n.toString().padLeft(2, '0');

String? _ordinal(String s) {
  final n = int.tryParse(s);
  if (n == null) return null;
  final suffix = (n % 100 >= 11 && n % 100 <= 13)
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

/// A cron expression in plain words ("Every day at 09:30"), or null when it is
/// too unusual to describe briefly.
/// `09:30`, or `9:30 AM` when [h24] is false (the phone's 12-hour setting).
String formatClock(int hour, int minute, {bool h24 = true}) {
  if (h24) return '${_two(hour)}:${_two(minute)}';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:${_two(minute)} ${hour < 12 ? 'AM' : 'PM'}';
}

String? describeCron(String expression, {bool h24 = true}) {
  final parts = expression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final [min, hour, dom, mon, dow] = parts;
  final isNum = RegExp(r'^\d+$');

  if (min == '*' && hour == '*' && dom == '*' && mon == '*' && dow == '*') return 'Every minute';
  final everyMin = RegExp(r'^\*/(\d+)$').firstMatch(min);
  if (everyMin != null && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    return 'Every ${everyMin[1]} minutes';
  }
  if (!isNum.hasMatch(min)) return null;
  final m = int.parse(min);
  if (hour == '*' && dom == '*' && mon == '*' && dow == '*') return 'Every hour at :${_two(m)}';
  final everyHour = RegExp(r'^\*/(\d+)$').firstMatch(hour);
  if (everyHour != null && dom == '*' && mon == '*' && dow == '*') {
    return 'Every ${everyHour[1]} hours at :${_two(m)}';
  }

  final hours = hour.split(',');
  if (!hours.every(isNum.hasMatch)) return null;
  final times = hours.map((h) => formatClock(int.parse(h), m, h24: h24)).toList();
  final at = times.length == 1
      ? 'at ${times.single}'
      : 'at ${times.sublist(0, times.length - 1).join(', ')} and ${times.last}';

  if (dom == '*' && mon == '*') {
    if (dow == '*') return 'Every day $at';
    if (dow == '1-5') return 'Weekdays $at';
    if (dow == '0,6' || dow == '6,0' || dow == '6-7' || dow == '6,7') return 'Weekends $at';
    final days = dow.split(',');
    if (days.every((d) => isNum.hasMatch(d) && int.parse(d) <= 7)) {
      final names = days.map((d) => _days[int.parse(d) % 7]).toList();
      final list = names.length == 1
          ? names.single
          : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
      return 'Every $list $at';
    }
    return null;
  }
  if (dow == '*' && isNum.hasMatch(dom)) {
    final day = _ordinal(dom)!;
    if (mon == '*') return 'Monthly on the $day $at';
    if (isNum.hasMatch(mon) && int.parse(mon) >= 1 && int.parse(mon) <= 12) {
      return 'Every year on ${_months[int.parse(mon) - 1]} $day $at';
    }
  }
  return null;
}

/// Model names to offer for each AI provider; the first is the default.
const modelSuggestions = <String, List<String>>{
  'anthropic': ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5', 'claude-fable-5-2'],
  'openai': ['gpt-5', 'gpt-5-mini', 'gpt-4.1', 'gpt-4o-mini'],
  'gemini': ['gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.5-flash-lite'],
  'openaiCompatible': ['llama3.2', 'qwen2.5', 'mistral', 'deepseek-r1'],
};

/// `2026-11-22T09:00:00+08:00`: what Google Calendar expects, in the phone's time zone.
String isoWithOffset(DateTime local) {
  final o = local.timeZoneOffset;
  final sign = o.isNegative ? '-' : '+';
  final h = _two(o.inHours.abs());
  final mm = _two(o.inMinutes.abs() % 60);
  return '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)}'
      'T${_two(local.hour)}:${_two(local.minute)}:00$sign$h:$mm';
}

/// Field paths in [item] for a "field" parameter: `name`, `user.email`, `tags` (lists are not entered).
List<String> fieldPaths(Map<String, Object?> item, {int depth = 2}) {
  final out = <String>[];
  void walk(Map<Object?, Object?> m, String prefix, int level) {
    for (final MapEntry(:key, :value) in m.entries) {
      final path = prefix.isEmpty ? '$key' : '$prefix.$key';
      out.add(path);
      if (value is Map && level < depth) walk(value, path, level + 1);
    }
  }

  walk(item, '', 1);
  return out;
}
