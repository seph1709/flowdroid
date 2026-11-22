/**
 * Five-field cron expressions: `minute hour day-of-month month day-of-week`.
 * Each field accepts `*`, numbers, ranges `a-b`, steps `* /n` or `a-b/n`, and
 * comma lists. Day-of-week runs 0-7 (0 and 7 are Sunday). As in Vixie cron,
 * when both day fields are restricted a day matches if either one does.
 */

import { fail } from './errors.ts';
import { jsTrim } from './value.ts';
import { checkTime, civilFromDays, MS_PER_DAY, MS_PER_MINUTE, weekdayFromDays } from './time.ts';

interface Field {
  name: string;
  min: number;
  max: number;
}

const FIELDS: Field[] = [
  { name: 'minute', min: 0, max: 59 },
  { name: 'hour', min: 0, max: 23 },
  { name: 'day of month', min: 1, max: 31 },
  { name: 'month', min: 1, max: 12 },
  { name: 'day of week', min: 0, max: 7 },
];

/** How far ahead to search: five years covers every satisfiable expression (Feb 29). */
const SEARCH_DAYS = 366 * 5;

interface Schedule {
  minutes: boolean[];
  hours: boolean[];
  daysOfMonth: boolean[];
  months: boolean[];
  daysOfWeek: boolean[];
  domRestricted: boolean;
  dowRestricted: boolean;
}

export function parseCron(expression: string): Schedule {
  const parts = jsTrim(expression).split(/\s+/);
  if (parts.length !== FIELDS.length) fail('CronError', 'expected 5 fields');
  const sets = FIELDS.map((field, i) => parseField(parts[i] ?? '', field));
  const daysOfWeek = sets[4]!;
  daysOfWeek[0] = daysOfWeek[0]! || daysOfWeek[7]!;
  return {
    minutes: sets[0]!,
    hours: sets[1]!,
    daysOfMonth: sets[2]!,
    months: sets[3]!,
    daysOfWeek,
    domRestricted: parts[2] !== '*',
    dowRestricted: parts[4] !== '*',
  };
}

function parseField(text: string, field: Field): boolean[] {
  const allowed: boolean[] = Array.from({ length: field.max + 1 }, () => false);
  for (const term of text.split(',')) {
    const pieces = term.split('/');
    if (pieces.length > 2) invalid(term, field);
    const [range = '', stepText] = pieces;
    const step = stepText === undefined ? 1 : parseNumber(stepText, field);
    if (step < 1) invalid(term, field);
    let [from, to] = [field.min, field.max];
    if (range !== '*') {
      const bounds = range.split('-');
      if (bounds.length > 2) invalid(term, field);
      const [a = '', b] = bounds;
      from = parseNumber(a, field);
      to = b === undefined ? (stepText === undefined ? from : field.max) : parseNumber(b, field);
    }
    if (from < field.min || to > field.max || from > to) invalid(term, field);
    for (let v = from; v <= to; v += step) allowed[v] = true;
  }
  return allowed;
}

function parseNumber(text: string, field: Field): number {
  if (!/^\d{1,2}$/.test(text)) invalid(text, field);
  return Number(text);
}

function invalid(term: string, field: Field): never {
  return fail('CronError', `invalid ${field.name} '${term}'`);
}

function dayMatches(s: Schedule, days: number): boolean {
  const { month, day } = civilFromDays(days);
  if (!s.months[month]) return false;
  const dom = s.daysOfMonth[day] === true;
  const dow = s.daysOfWeek[weekdayFromDays(days)] === true;
  if (s.domRestricted && s.dowRestricted) return dom || dow;
  return dom && dow;
}

/**
 * The first matching minute strictly after `afterMs`, in UTC milliseconds,
 * for a clock `utcOffsetMinutes` ahead of UTC; -1 when nothing matches.
 */
export function nextRun(expression: string, afterMs: number, utcOffsetMinutes: number): number {
  const s = parseCron(expression);
  const after = checkTime(afterMs, 'CronError', 'time');
  if (!Number.isInteger(utcOffsetMinutes) || Math.abs(utcOffsetMinutes) > 1440) fail('CronError', 'UTC offset is out of range');
  const offsetMs = utcOffsetMinutes * MS_PER_MINUTE;
  const firstMinute = Math.floor((after + offsetMs) / MS_PER_MINUTE) + 1;
  let days = Math.floor(firstMinute / 1440);
  let minuteOfDay = firstMinute - days * 1440;
  for (let n = 0; n < SEARCH_DAYS; n++, days++, minuteOfDay = 0) {
    if (!dayMatches(s, days)) continue;
    for (let m = minuteOfDay; m < 1440; m++) {
      if (s.hours[Math.floor(m / 60)] && s.minutes[m % 60]) return days * MS_PER_DAY + m * MS_PER_MINUTE - offsetMs;
    }
  }
  return -1;
}
