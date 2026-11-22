import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { nextCronRun } from '../src/api.ts';

const at = (iso: string): number => Date.parse(iso);
const next = (expr: string, afterIso: string, offset = 0): string => new Date(nextCronRun(expr, at(afterIso), offset)).toISOString();

describe('nextCronRun', () => {
  it('finds the next matching minute strictly after the given time', () => {
    assert.equal(next('* * * * *', '2026-01-01T00:00:00.000Z'), '2026-01-01T00:01:00.000Z');
    assert.equal(next('0 * * * *', '2026-01-01T00:00:30.000Z'), '2026-01-01T01:00:00.000Z');
    assert.equal(next('*/15 9-17 * * *', '2026-01-01T17:50:00.000Z'), '2026-01-02T09:00:00.000Z');
  });

  it('handles weekdays, month days and the either-day rule', () => {
    assert.equal(next('30 9 * * 1-5', '2026-11-21T12:00:00.000Z'), '2026-11-23T09:30:00.000Z');
    assert.equal(next('0 0 1 * *', '2026-02-10T00:00:00.000Z'), '2026-03-01T00:00:00.000Z');
    assert.equal(next('0 0 13 * 5', '2026-11-01T00:00:00.000Z'), '2026-11-06T00:00:00.000Z', 'Friday or the 13th');
    assert.equal(next('0 12 * * 7', '2026-11-21T00:00:00.000Z'), '2026-11-22T12:00:00.000Z', '7 is Sunday');
  });

  it('applies the UTC offset of the local clock', () => {
    assert.equal(next('0 9 * * *', '2026-06-01T00:00:00.000Z', 480), '2026-06-01T01:00:00.000Z');
    assert.equal(next('0 9 * * *', '2026-06-01T02:00:00.000Z', 480), '2026-06-02T01:00:00.000Z');
  });

  it('waits for leap days and gives up on impossible dates', () => {
    assert.equal(next('0 0 29 2 *', '2026-03-01T00:00:00.000Z'), '2028-02-29T00:00:00.000Z');
    assert.equal(nextCronRun('0 0 30 2 *', 0, 0), -1);
  });

  it('rejects malformed expressions and times', () => {
    const fails = (expr: string, message: string, after = 0, offset = 0): void => {
      assert.throws(() => nextCronRun(expr, after, offset), { message });
    };
    fails('* * * *', 'CronError: expected 5 fields');
    fails('60 * * * *', "CronError: invalid minute '60'");
    fails('*/0 * * * *', "CronError: invalid minute '*/0'");
    fails('5-1 * * * *', "CronError: invalid minute '5-1'");
    fails('* * 0 * *', "CronError: invalid day of month '0'");
    fails('* * * * *', 'CronError: time is out of range', Number.NaN);
    fails('* * * * *', 'CronError: UTC offset is out of range', 0, 1.5);
  });
});
