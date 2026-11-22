//! Calendar arithmetic on integer days since 1970-01-01 (proleptic Gregorian).

use crate::errors::{ErrorKind, Result, fail};

pub const MS_PER_MINUTE: i64 = 60_000;
pub const MS_PER_DAY: i64 = 86_400_000;
/// The range `Date` supports: ±100,000,000 days around the epoch.
pub const MAX_TIME_MS: f64 = 8.64e15;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CivilDate {
    pub year: i64,
    pub month: i64,
    pub day: i64,
}

/// Howard Hinnant's `civil_from_days`.
#[must_use]
pub fn civil_from_days(days: i64) -> CivilDate {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    CivilDate {
        year: yoe + era * 400 + i64::from(month <= 2),
        month,
        day,
    }
}

/// 0 = Sunday ... 6 = Saturday.
#[must_use]
pub fn weekday_from_days(days: i64) -> i64 {
    (days + 4).rem_euclid(7)
}

/// Checks a millisecond timestamp argument and truncates it to an integer.
pub fn check_time(ms: f64, kind: ErrorKind, what: &str) -> Result<i64> {
    if !ms.is_finite() || ms.abs() > MAX_TIME_MS {
        return fail(kind, format!("{what} is out of range"));
    }
    Ok(ms.trunc() as i64)
}

/// ISO-8601 in UTC with milliseconds, like `Date.prototype.toISOString`.
#[must_use]
pub fn iso_string(ms: i64) -> String {
    let days = ms.div_euclid(MS_PER_DAY);
    let rest = ms.rem_euclid(MS_PER_DAY);
    let CivilDate { year, month, day } = civil_from_days(days);
    let year_text = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else {
        format!("{}{:06}", if year < 0 { '-' } else { '+' }, year.abs())
    };
    format!(
        "{year_text}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        rest / 3_600_000,
        rest % 3_600_000 / MS_PER_MINUTE,
        rest % MS_PER_MINUTE / 1000,
        rest % 1000
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_iso_dates() {
        assert_eq!(iso_string(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_string(1_795_249_800_000), "2026-11-21T08:30:00.000Z");
        assert_eq!(iso_string(-1), "1969-12-31T23:59:59.999Z");
        assert_eq!(
            iso_string(-8_640_000_000_000_000),
            "-271821-04-20T00:00:00.000Z"
        );
        assert_eq!(
            iso_string(8_640_000_000_000_000),
            "+275760-09-13T00:00:00.000Z"
        );
    }
}
