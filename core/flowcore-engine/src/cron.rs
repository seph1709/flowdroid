//! Five-field cron expressions: `minute hour day-of-month month day-of-week`.
//!
//! Each field accepts `*`, numbers, ranges `a-b`, steps `*/n` or `a-b/n`, and
//! comma lists. Day-of-week runs 0-7 (0 and 7 are Sunday). As in Vixie cron,
//! when both day fields are restricted a day matches if either one does.

use crate::errors::{ErrorKind, Result, fail};
use crate::time::{MS_PER_DAY, MS_PER_MINUTE, check_time, civil_from_days, weekday_from_days};
use crate::value::{is_js_whitespace, js_trim};

struct Field {
    name: &'static str,
    min: usize,
    max: usize,
}

const FIELDS: [Field; 5] = [
    Field {
        name: "minute",
        min: 0,
        max: 59,
    },
    Field {
        name: "hour",
        min: 0,
        max: 23,
    },
    Field {
        name: "day of month",
        min: 1,
        max: 31,
    },
    Field {
        name: "month",
        min: 1,
        max: 12,
    },
    Field {
        name: "day of week",
        min: 0,
        max: 7,
    },
];

/// How far ahead to search: five years covers every satisfiable expression (Feb 29).
const SEARCH_DAYS: i64 = 366 * 5;
const MINUTES_PER_DAY: i64 = 1440;

struct Schedule {
    minutes: Vec<bool>,
    hours: Vec<bool>,
    days_of_month: Vec<bool>,
    months: Vec<bool>,
    days_of_week: Vec<bool>,
    dom_restricted: bool,
    dow_restricted: bool,
}

fn parse_cron(expression: &str) -> Result<Schedule> {
    let parts: Vec<&str> = js_trim(expression)
        .split(is_js_whitespace)
        .filter(|p| !p.is_empty())
        .collect();
    if parts.len() != FIELDS.len() {
        return fail(ErrorKind::Cron, "expected 5 fields");
    }
    let mut sets = parts
        .iter()
        .zip(&FIELDS)
        .map(|(text, field)| parse_field(text, field))
        .collect::<Result<Vec<_>>>()?;
    sets[4][0] = sets[4][0] || sets[4][7];
    let [minutes, hours, days_of_month, months, days_of_week]: [Vec<bool>; 5] = sets
        .try_into()
        .map_err(|_| crate::errors::Error::new(ErrorKind::Cron, "expected 5 fields"))?;
    Ok(Schedule {
        minutes,
        hours,
        days_of_month,
        months,
        days_of_week,
        dom_restricted: parts[2] != "*",
        dow_restricted: parts[4] != "*",
    })
}

fn parse_field(text: &str, field: &Field) -> Result<Vec<bool>> {
    let mut allowed = vec![false; field.max + 1];
    for term in text.split(',') {
        let pieces: Vec<&str> = term.split('/').collect();
        if pieces.len() > 2 {
            return invalid(term, field);
        }
        let range = pieces[0];
        let step_text = pieces.get(1).copied();
        let step = match step_text {
            None => 1,
            Some(s) => parse_number(s, field)?,
        };
        if step < 1 {
            return invalid(term, field);
        }
        let (mut from, mut to) = (field.min, field.max);
        if range != "*" {
            let bounds: Vec<&str> = range.split('-').collect();
            if bounds.len() > 2 {
                return invalid(term, field);
            }
            from = parse_number(bounds[0], field)?;
            to = match (bounds.get(1), step_text) {
                (Some(b), _) => parse_number(b, field)?,
                (None, None) => from,
                (None, Some(_)) => field.max,
            };
        }
        if from < field.min || to > field.max || from > to {
            return invalid(term, field);
        }
        for v in (from..=to).step_by(step) {
            allowed[v] = true;
        }
    }
    Ok(allowed)
}

fn parse_number(text: &str, field: &Field) -> Result<usize> {
    if text.is_empty() || text.len() > 2 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return invalid(text, field);
    }
    text.parse().or_else(|_| invalid(text, field))
}

fn invalid<T>(term: &str, field: &Field) -> Result<T> {
    fail(ErrorKind::Cron, format!("invalid {} '{term}'", field.name))
}

fn day_matches(s: &Schedule, days: i64) -> bool {
    let date = civil_from_days(days);
    if !s.months[date.month as usize] {
        return false;
    }
    let dom = s.days_of_month[date.day as usize];
    let dow = s.days_of_week[weekday_from_days(days) as usize];
    if s.dom_restricted && s.dow_restricted {
        dom || dow
    } else {
        dom && dow
    }
}

/// The first matching minute strictly after `after_ms`, in UTC milliseconds,
/// for a clock `utc_offset_minutes` ahead of UTC; -1 when nothing matches.
pub fn next_run(expression: &str, after_ms: f64, utc_offset_minutes: f64) -> Result<f64> {
    let s = parse_cron(expression)?;
    let after = check_time(after_ms, ErrorKind::Cron, "time")?;
    let offset_ok = utc_offset_minutes.fract() == 0.0 && utc_offset_minutes.abs() <= 1440.0;
    if !offset_ok {
        return fail(ErrorKind::Cron, "UTC offset is out of range");
    }
    let offset_ms = utc_offset_minutes as i64 * MS_PER_MINUTE;
    let first_minute = (after + offset_ms).div_euclid(MS_PER_MINUTE) + 1;
    let first_day = first_minute.div_euclid(MINUTES_PER_DAY);
    for days in first_day..first_day + SEARCH_DAYS {
        if !day_matches(&s, days) {
            continue;
        }
        let from = if days == first_day {
            first_minute - first_day * MINUTES_PER_DAY
        } else {
            0
        };
        if let Some(m) = (from..MINUTES_PER_DAY)
            .find(|m| s.hours[(m / 60) as usize] && s.minutes[(m % 60) as usize])
        {
            return Ok((days * MS_PER_DAY + m * MS_PER_MINUTE - offset_ms) as f64);
        }
    }
    Ok(-1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_next_weekday_slot() {
        // Saturday 2026-11-21 12:00 UTC, clock at UTC+8: next is Monday 09:30 local.
        assert_eq!(
            next_run("30 9 * * 1-5", 1_795_262_400_000.0, 480.0),
            Ok(1_795_397_400_000.0)
        );
        assert_eq!(next_run("0 0 30 2 *", 0.0, 0.0), Ok(-1.0));
    }

    #[test]
    fn reports_bad_fields() {
        let err = |e: &str| next_run(e, 0.0, 0.0).unwrap_err().to_string();
        assert_eq!(err("* * * *"), "CronError: expected 5 fields");
        assert_eq!(err("*/x * * * *"), "CronError: invalid minute 'x'");
        assert_eq!(err("5-1 * * * *"), "CronError: invalid minute '5-1'");
    }
}
