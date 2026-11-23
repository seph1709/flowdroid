import 'package:flowdroid/core/param_helpers.dart';
import 'package:flowdroid/core/schedule_spec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calendar choices become cron', () {
    expect(const ScheduleSpec(repeat: Repeat.minutes, every: 15).toCron(), '*/15 * * * *');
    expect(const ScheduleSpec(repeat: Repeat.hourly, every: 1, minute: 30).toCron(), '30 * * * *');
    expect(const ScheduleSpec(repeat: Repeat.hourly, every: 6, minute: 0).toCron(), '0 */6 * * *');
    expect(const ScheduleSpec(hour: 7, minute: 5).toCron(), '5 7 * * *');
    expect(const ScheduleSpec(repeat: Repeat.weekly, hour: 8, weekdays: {1, 2, 3, 4, 5}).toCron(), '0 8 * * 1-5');
    expect(const ScheduleSpec(repeat: Repeat.weekly, hour: 8, weekdays: {0, 6}).toCron(), '0 8 * * 0,6');
    expect(const ScheduleSpec(repeat: Repeat.monthly, hour: 9, monthDays: {1, 15}).toCron(), '0 9 1,15 * *');
  });

  test('cron comes back as the same choices', () {
    for (final cron in [
      '*/5 * * * *',
      '45 * * * *',
      '0 */4 * * *',
      '30 9 * * *',
      '0 8 * * 1-5',
      '0 10 * * 0,6',
      '15 6 1,10-12 * *',
    ]) {
      expect(ScheduleSpec.fromCron(cron)?.toCron(), cron, reason: cron);
    }
    expect(ScheduleSpec.fromCron('0 9 * * 7')?.weekdays, {0}, reason: '7 is Sunday too');
    expect(ScheduleSpec.fromCron('0 9 1 6 *'), isNull, reason: 'yearly is for the cron editor');
    expect(ScheduleSpec.fromCron('nonsense'), isNull);
  });

  test('every choice can be described in words', () {
    for (final s in [
      const ScheduleSpec(repeat: Repeat.minutes, every: 10),
      const ScheduleSpec(repeat: Repeat.hourly, every: 2),
      const ScheduleSpec(),
      const ScheduleSpec(repeat: Repeat.weekly, weekdays: {1, 3}),
      const ScheduleSpec(repeat: Repeat.monthly, monthDays: {1}),
    ]) {
      expect(describeCron(s.toCron()), isNotNull, reason: s.toCron());
    }
  });
}
