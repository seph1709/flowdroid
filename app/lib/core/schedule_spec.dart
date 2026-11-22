/// A schedule people pick from a calendar (how often, which days, what time),
/// converted to and from the cron text the Schedule Trigger stores.
library;

enum Repeat { minutes, hourly, daily, weekly, monthly }

class ScheduleSpec {
  const ScheduleSpec({
    this.repeat = Repeat.daily,
    this.every = 15,
    this.hour = 9,
    this.minute = 0,
    this.weekdays = const {1, 2, 3, 4, 5},
    this.monthDays = const {1},
  });

  final Repeat repeat;

  /// Minutes between runs ([Repeat.minutes]) or hours between runs ([Repeat.hourly]).
  final int every;
  final int hour;
  final int minute;

  /// 0 = Sunday … 6 = Saturday, as cron counts them.
  final Set<int> weekdays;

  /// 1–31.
  final Set<int> monthDays;

  ScheduleSpec copyWith({
    Repeat? repeat,
    int? every,
    int? hour,
    int? minute,
    Set<int>? weekdays,
    Set<int>? monthDays,
  }) => ScheduleSpec(
    repeat: repeat ?? this.repeat,
    every: every ?? this.every,
    hour: hour ?? this.hour,
    minute: minute ?? this.minute,
    weekdays: weekdays ?? this.weekdays,
    monthDays: monthDays ?? this.monthDays,
  );

  static String _list(Set<int> values) {
    final sorted = values.toList()..sort();
    // Runs of three or more become ranges: 1,2,3,4,5 → 1-5.
    final parts = <String>[];
    var i = 0;
    while (i < sorted.length) {
      var j = i;
      while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
        j++;
      }
      parts.add(j - i >= 2 ? '${sorted[i]}-${sorted[j]}' : sorted.sublist(i, j + 1).join(','));
      i = j + 1;
    }
    return parts.join(',');
  }

  String toCron() => switch (repeat) {
    Repeat.minutes => every <= 1 ? '* * * * *' : '*/$every * * * *',
    Repeat.hourly => every <= 1 ? '$minute * * * *' : '$minute */$every * * *',
    Repeat.daily => '$minute $hour * * *',
    Repeat.weekly => '$minute $hour * * ${weekdays.isEmpty ? '*' : _list(weekdays)}',
    Repeat.monthly => '$minute $hour ${monthDays.isEmpty ? '1' : _list(monthDays)} * *',
  };

  /// The calendar choice behind [cron], or null when it is something the picker can't show.
  static ScheduleSpec? fromCron(String cron) {
    final f = cron.trim().split(RegExp(r'\s+'));
    if (f.length != 5) return null;
    final [mi, h, dom, mon, dow] = f;
    if (mon != '*') return null;
    int? n(String s) => RegExp(r'^\d+$').hasMatch(s) ? int.parse(s) : null;
    int? step(String s) => RegExp(r'^\*/(\d+)$').firstMatch(s)?.group(1) == null ? null : int.parse(s.substring(2));
    Set<int>? set(String s, int max) {
      final out = <int>{};
      for (final part in s.split(',')) {
        final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(part);
        if (range != null) {
          final a = int.parse(range[1]!), b = int.parse(range[2]!);
          if (a > b || b > max) return null;
          for (var v = a; v <= b; v++) {
            out.add(v);
          }
        } else if (n(part) case final v? when v <= max) {
          out.add(v);
        } else {
          return null;
        }
      }
      return out;
    }

    if (h == '*' && dom == '*' && dow == '*') {
      if (mi == '*') return const ScheduleSpec(repeat: Repeat.minutes, every: 1);
      if (step(mi) case final s?) return ScheduleSpec(repeat: Repeat.minutes, every: s);
      if (n(mi) case final m?) return ScheduleSpec(repeat: Repeat.hourly, every: 1, minute: m);
      return null;
    }
    final m = n(mi);
    if (m == null || m > 59) return null;
    if (step(h) case final s? when dom == '*' && dow == '*') {
      return ScheduleSpec(repeat: Repeat.hourly, every: s, minute: m);
    }
    final hour = n(h);
    if (hour == null || hour > 23) return null;
    if (dom == '*' && dow == '*') return ScheduleSpec(repeat: Repeat.daily, hour: hour, minute: m);
    if (dom == '*') {
      final days = set(dow, 7)?.map((d) => d % 7).toSet();
      return days == null ? null : ScheduleSpec(repeat: Repeat.weekly, hour: hour, minute: m, weekdays: days);
    }
    if (dow == '*') {
      final days = set(dom, 31);
      if (days == null || days.contains(0)) return null;
      return ScheduleSpec(repeat: Repeat.monthly, hour: hour, minute: m, monthDays: days);
    }
    return null;
  }
}
