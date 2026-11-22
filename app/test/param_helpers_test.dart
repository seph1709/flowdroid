import 'package:flowdroid/core/param_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('IDs come out of pasted links', () {
    expect(
      idFromLink(IdKind.sheet, 'https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-x/edit#gid=0'),
      '1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-x',
    );
    expect(idFromLink(IdKind.driveFolder, 'https://drive.google.com/drive/folders/0B1x2y3z4w5v6u?usp=sharing'), '0B1x2y3z4w5v6u');
    expect(
      idFromLink(IdKind.driveFile, 'https://drive.google.com/file/d/1QwErTyUiOpAsDfGhJkLzXcV/view'),
      '1QwErTyUiOpAsDfGhJkLzXcV',
    );
    expect(
      idFromLink(IdKind.notionDatabase, 'https://www.notion.so/team/Tasks-0123456789abcdef0123456789abcdef?v=ff'),
      '0123456789abcdef0123456789abcdef',
    );
    expect(idFromLink(IdKind.airtableBase, 'https://airtable.com/appAbCdEfGhIjKlMn/tblZyXwVuTsRqPoNm/viw1'), 'appAbCdEfGhIjKlMn');
    expect(idFromLink(IdKind.airtableTable, 'https://airtable.com/appAbCdEfGhIjKlMn/tblZyXwVuTsRqPoNm/viw1'), 'tblZyXwVuTsRqPoNm');
    // Already an ID, an expression, or nothing to find: leave it alone.
    expect(idFromLink(IdKind.airtableBase, 'appAbCdEfGhIjKlMn'), isNull);
    expect(idFromLink(IdKind.sheet, r'{{ $json.sheet }}'), isNull);
    expect(idFromLink(IdKind.notionDatabase, 'my notes'), isNull);
  });

  test('cron in plain words', () {
    expect(describeCron('* * * * *'), 'Every minute');
    expect(describeCron('*/5 * * * *'), 'Every 5 minutes');
    expect(describeCron('15 * * * *'), 'Every hour at :15');
    expect(describeCron('0 */6 * * *'), 'Every 6 hours at :00');
    expect(describeCron('30 9 * * *'), 'Every day at 09:30');
    expect(describeCron('0 8 * * 1-5'), 'Weekdays at 08:00');
    expect(describeCron('0 10 * * 0,6'), 'Weekends at 10:00');
    expect(describeCron('0 9 * * 1,3'), 'Every Monday and Wednesday at 09:00');
    expect(describeCron('0 9,17 * * *'), 'Every day at 09:00 and 17:00');
    expect(describeCron('0 9 1 * *'), 'Monthly on the 1st at 09:00');
    expect(describeCron('0 9 22 11 *'), 'Every year on November 22nd at 09:00');
    expect(describeCron('0 9 1-7 * 1'), isNull);
    expect(describeCron('nonsense'), isNull);
    for (final p in cronPresets) {
      expect(describeCron(p.cron), isNotNull, reason: p.cron);
    }
  });

  test('times follow the phone: 24-hour or AM/PM', () {
    expect(formatClock(9, 5), '09:05');
    expect(formatClock(0, 0, h24: false), '12:00 AM');
    expect(formatClock(12, 30, h24: false), '12:30 PM');
    expect(formatClock(21, 0, h24: false), '9:00 PM');
    expect(describeCron('0 21 * * 1-5', h24: false), 'Weekdays at 9:00 PM');
    expect(describeCron('0 9,17 * * *', h24: false), 'Every day at 9:00 AM and 5:00 PM');
  });

  test('ISO dates carry the time zone offset', () {
    final s = isoWithOffset(DateTime(2026, 11, 22, 9, 5));
    expect(s, startsWith('2026-11-22T09:05:00'));
    expect(RegExp(r'[+-]\d\d:\d\d$').hasMatch(s), isTrue);
    expect(DateTime.parse(s).toLocal(), DateTime(2026, 11, 22, 9, 5));
  });

  test('field paths from an input item', () {
    expect(
      fieldPaths({
        'id': 1,
        'user': {
          'email': 'a@b.c',
          'address': {'city': 'X'},
        },
        'tags': ['a'],
      }),
      ['id', 'user', 'user.email', 'user.address', 'tags'],
    );
  });

  test('every AI provider has model suggestions', () {
    for (final p in ['anthropic', 'openai', 'gemini', 'openaiCompatible']) {
      expect(modelSuggestions[p], isNotEmpty);
    }
    expect(modelSuggestions['anthropic']!.first, 'claude-opus-5-5');
  });
}
