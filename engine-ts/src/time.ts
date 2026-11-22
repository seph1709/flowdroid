/**
 * Calendar arithmetic without `Date`, so the Rust port can match it exactly.
 * Day numbers count from 1970-01-01 (day 0) in the proleptic Gregorian calendar.
 */

import { fail } from './errors.ts';

export const MS_PER_MINUTE = 60_000;
export const MS_PER_DAY = 86_400_000;
/** The range `Date` supports: ±100,000,000 days around the epoch. */
export const MAX_TIME_MS = 8.64e15;

export interface CivilDate {
  year: number;
  month: number; // 1-12
  day: number; // 1-31
}

/** Howard Hinnant's `civil_from_days`. */
export function civilFromDays(days: number): CivilDate {
  const z = days + 719_468;
  const era = Math.floor(z / 146_097);
  const doe = z - era * 146_097;
  const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36_524) - Math.floor(doe / 146_096)) / 365);
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const day = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const month = mp < 10 ? mp + 3 : mp - 9;
  return { year: yoe + era * 400 + (month <= 2 ? 1 : 0), month, day };
}

/** 0 = Sunday … 6 = Saturday. */
export function weekdayFromDays(days: number): number {
  return (((days + 4) % 7) + 7) % 7;
}

/** Checks a millisecond timestamp argument and truncates it to an integer. */
export function checkTime(ms: number, kind: 'InputError' | 'CronError', what: string): number {
  if (!Number.isFinite(ms) || Math.abs(ms) > MAX_TIME_MS) fail(kind, `${what} is out of range`);
  return Math.trunc(ms) + 0;
}

/** ISO-8601 in UTC with milliseconds, like `Date.prototype.toISOString`. */
export function isoString(ms: number): string {
  const days = Math.floor(ms / MS_PER_DAY);
  const rest = ms - days * MS_PER_DAY;
  const { year, month, day } = civilFromDays(days);
  const yearText = year >= 0 && year <= 9999
    ? pad(year, 4)
    : (year < 0 ? '-' : '+') + pad(Math.abs(year), 6);
  const hh = Math.floor(rest / 3_600_000);
  const mm = Math.floor((rest % 3_600_000) / MS_PER_MINUTE);
  const ss = Math.floor((rest % MS_PER_MINUTE) / 1000);
  const mss = rest % 1000;
  return `${yearText}-${pad(month, 2)}-${pad(day, 2)}T${pad(hh, 2)}:${pad(mm, 2)}:${pad(ss, 2)}.${pad(mss, 3)}Z`;
}

function pad(n: number, width: number): string {
  return String(n).padStart(width, '0');
}
