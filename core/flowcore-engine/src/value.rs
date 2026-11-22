//! The JSON value model and the coercion rules shared by every module.
//!
//! Mirrors `engine-ts/src/value.ts`. `Null` doubles as "undefined". Strings
//! are measured and compared in UTF-16 code units, as JavaScript does, and
//! objects serialize in JavaScript property order (array-index keys first).

use std::cmp::Ordering;
use std::fmt::Write as _;

use indexmap::IndexMap;

pub type Obj = IndexMap<String, Val>;

#[derive(Debug, Clone, Default)]
pub enum Val {
    #[default]
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Val>),
    Obj(Obj),
}

pub static NULL: Val = Val::Null;

impl Val {
    #[must_use]
    pub fn as_obj(&self) -> Option<&Obj> {
        match self {
            Self::Obj(o) => Some(o),
            _ => None,
        }
    }

    #[must_use]
    pub fn as_arr(&self) -> Option<&Vec<Val>> {
        match self {
            Self::Arr(a) => Some(a),
            _ => None,
        }
    }

    #[must_use]
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::Str(s) => Some(s),
            _ => None,
        }
    }

    #[must_use]
    pub fn is_null(&self) -> bool {
        matches!(self, Self::Null)
    }

    /// True for `Val::Bool(true)` only.
    #[must_use]
    pub fn is_true(&self) -> bool {
        matches!(self, Self::Bool(true))
    }

    /// True when this is exactly the string `s`.
    #[must_use]
    pub fn is_str(&self, s: &str) -> bool {
        self.as_str() == Some(s)
    }
}

impl From<&str> for Val {
    fn from(s: &str) -> Self {
        Self::Str(s.to_owned())
    }
}

impl From<String> for Val {
    fn from(s: String) -> Self {
        Self::Str(s)
    }
}

impl From<f64> for Val {
    fn from(n: f64) -> Self {
        Self::Num(n)
    }
}

impl From<usize> for Val {
    fn from(n: usize) -> Self {
        Self::Num(n as f64)
    }
}

impl From<bool> for Val {
    fn from(b: bool) -> Self {
        Self::Bool(b)
    }
}

impl From<Obj> for Val {
    fn from(o: Obj) -> Self {
        Self::Obj(o)
    }
}

impl From<Vec<Val>> for Val {
    fn from(a: Vec<Val>) -> Self {
        Self::Arr(a)
    }
}

impl<T: Into<Val>> From<Option<T>> for Val {
    fn from(v: Option<T>) -> Self {
        v.map_or(Self::Null, Into::into)
    }
}

/// Builds an object from `(key, value)` pairs, in order.
#[must_use]
pub fn obj<const N: usize>(entries: [(&str, Val); N]) -> Obj {
    entries
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v))
        .collect()
}

/// Wraps items (objects) as a JSON list.
#[must_use]
pub fn items_val(items: &[Obj]) -> Val {
    Val::Arr(items.iter().cloned().map(Val::Obj).collect())
}

#[must_use]
pub fn get_key<'a>(o: &'a Obj, key: &str) -> &'a Val {
    o.get(key).unwrap_or(&NULL)
}

/// Structural equality; `NaN` is never equal to itself.
#[must_use]
pub fn deep_equal(a: &Val, b: &Val) -> bool {
    match (a, b) {
        (Val::Null, Val::Null) => true,
        (Val::Bool(x), Val::Bool(y)) => x == y,
        (Val::Num(x), Val::Num(y)) => x == y,
        (Val::Str(x), Val::Str(y)) => x == y,
        (Val::Arr(x), Val::Arr(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| deep_equal(p, q))
        }
        (Val::Obj(x), Val::Obj(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.get(k).is_some_and(|w| deep_equal(v, w)))
        }
        _ => false,
    }
}

#[must_use]
pub fn truthy(v: &Val) -> bool {
    match v {
        Val::Null => false,
        Val::Bool(b) => *b,
        Val::Num(n) => *n != 0.0 && !n.is_nan(),
        Val::Str(s) => !s.is_empty(),
        Val::Arr(_) | Val::Obj(_) => true,
    }
}

/// Characters removed by JavaScript's `String.prototype.trim`.
#[must_use]
pub fn is_js_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

#[must_use]
pub fn js_trim(s: &str) -> &str {
    s.trim_matches(is_js_whitespace)
}

/// Matches `^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$` with ASCII digits.
fn is_decimal(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0;
    let digits = |i: &mut usize| {
        let start = *i;
        while *i < b.len() && b[*i].is_ascii_digit() {
            *i += 1;
        }
        *i - start
    };
    if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
        i += 1;
    }
    let int_digits = digits(&mut i);
    let mut frac_digits = 0;
    if i < b.len() && b[i] == b'.' {
        i += 1;
        frac_digits = digits(&mut i);
    }
    if int_digits == 0 && frac_digits == 0 {
        return false;
    }
    if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
        i += 1;
        if i < b.len() && (b[i] == b'+' || b[i] == b'-') {
            i += 1;
        }
        if digits(&mut i) == 0 {
            return false;
        }
    }
    i == b.len()
}

#[must_use]
pub fn to_num(v: &Val) -> f64 {
    match v {
        Val::Null => 0.0,
        Val::Bool(b) => f64::from(u8::from(*b)),
        Val::Num(n) => *n,
        Val::Str(s) => {
            let s = js_trim(s);
            if s.is_empty() {
                0.0
            } else if is_decimal(s) {
                s.parse().unwrap_or(f64::NAN)
            } else {
                f64::NAN
            }
        }
        Val::Arr(_) | Val::Obj(_) => f64::NAN,
    }
}

/// `ToIntegerOrInfinity`: NaN becomes 0, everything else truncates (no `-0`).
#[must_use]
pub fn to_int(v: &Val) -> f64 {
    let n = to_num(v);
    if n.is_nan() { 0.0 } else { n.trunc() + 0.0 }
}

/// JavaScript's `Number.prototype.toString()` for base 10.
#[must_use]
pub fn format_number(n: f64) -> String {
    if n.is_nan() {
        return "NaN".into();
    }
    if n == 0.0 {
        return "0".into();
    }
    if n.is_infinite() {
        return if n > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    // `{:e}` prints the shortest digits that round-trip, e.g. "1.5e-7".
    let sci = format!("{:e}", n.abs());
    let (mantissa, exp) = sci.split_once('e').unwrap_or((sci.as_str(), "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let k = digits.len() as i32;
    let point = exp + 1;
    let mut out = String::with_capacity(digits.len() + 8);
    if n < 0.0 {
        out.push('-');
    }
    if k <= point && point <= 21 {
        out.push_str(&digits);
        out.push_str(&"0".repeat((point - k) as usize));
    } else if 0 < point && point <= 21 {
        out.push_str(&digits[..point as usize]);
        out.push('.');
        out.push_str(&digits[point as usize..]);
    } else if -6 < point && point <= 0 {
        out.push_str("0.");
        out.push_str(&"0".repeat((-point) as usize));
        out.push_str(&digits);
    } else {
        let e = point - 1;
        out.push_str(&digits[..1]);
        if k > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        out.push(if e >= 0 { '+' } else { '-' });
        out.push_str(&e.abs().to_string());
    }
    out
}

/// Text form of a value: lists and objects become compact JSON.
#[must_use]
pub fn to_str(v: &Val) -> String {
    match v {
        Val::Null => "null".into(),
        Val::Bool(b) => b.to_string(),
        Val::Num(n) => format_number(*n),
        Val::Str(s) => s.clone(),
        Val::Arr(_) | Val::Obj(_) => stringify(v),
    }
}

/// Text spliced into a template: like [`to_str`], but `null` renders as nothing.
#[must_use]
pub fn to_template_str(v: &Val) -> String {
    if v.is_null() {
        String::new()
    } else {
        to_str(v)
    }
}

/// `JSON.stringify` without indentation.
#[must_use]
pub fn stringify(v: &Val) -> String {
    let mut out = String::new();
    write_json(v, &mut out);
    out
}

fn write_json(v: &Val, out: &mut String) {
    match v {
        Val::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Val::Num(n) if n.is_finite() => out.push_str(&format_number(*n)),
        // Like JSON.stringify, non-finite numbers serialize as null.
        Val::Null | Val::Num(_) => out.push_str("null"),
        Val::Str(s) => write_json_string(s, out),
        Val::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json(item, out);
            }
            out.push(']');
        }
        Val::Obj(o) => {
            out.push('{');
            for (i, (key, value)) in ordered_entries(o).into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json_string(key, out);
                out.push(':');
                write_json(value, out);
            }
            out.push('}');
        }
    }
}

fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A canonical array index (`"0"`, `"17"`, below 2^32 - 1), which JavaScript orders first.
fn array_index(key: &str) -> Option<u32> {
    let canonical = !key.is_empty()
        && key.len() <= 10
        && key.bytes().all(|b| b.is_ascii_digit())
        && (key == "0" || !key.starts_with('0'));
    if !canonical {
        return None;
    }
    key.parse::<u64>()
        .ok()
        .filter(|&n| n < 4_294_967_295)
        .map(|n| n as u32)
}

/// Entries in JavaScript property order: array-index keys ascending, then insertion order.
#[must_use]
pub fn ordered_entries(o: &Obj) -> Vec<(&String, &Val)> {
    let mut indexed = Vec::new();
    let mut rest = Vec::new();
    for (k, v) in o {
        match array_index(k) {
            Some(i) => indexed.push((i, k, v)),
            None => rest.push((k, v)),
        }
    }
    indexed.sort_by_key(|e| e.0);
    indexed
        .into_iter()
        .map(|(_, k, v)| (k, v))
        .chain(rest)
        .collect()
}

/// Orders strings by UTF-16 code units, as JavaScript's `<` does.
#[must_use]
pub fn compare_strings(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

#[must_use]
pub fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

#[must_use]
pub fn is_empty(v: &Val) -> bool {
    match v {
        Val::Null => true,
        Val::Str(s) => s.is_empty(),
        Val::Arr(a) => a.is_empty(),
        Val::Obj(o) => o.is_empty(),
        Val::Bool(_) | Val::Num(_) => false,
    }
}

fn all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// Reads a dotted path such as `user.tags.0`; numeric parts index lists.
#[must_use]
pub fn get_path<'a>(root: &'a Val, path: &str) -> &'a Val {
    let mut cur = root;
    for part in path.split('.') {
        cur = match cur {
            Val::Arr(list) if all_digits(part) => {
                let index: f64 = part.parse().unwrap_or(f64::INFINITY);
                if index < list.len() as f64 {
                    &list[index as usize]
                } else {
                    &NULL
                }
            }
            Val::Obj(o) => get_key(o, part),
            _ => return &NULL,
        };
    }
    cur
}

/// Writes a dotted path, creating (or replacing non-object) parents as needed.
pub fn set_path(root: &mut Obj, path: &str, v: Val) {
    let mut parts: Vec<&str> = path.split('.').collect();
    let last = parts.pop().unwrap_or_default();
    let mut cur = root;
    for part in parts {
        let slot = cur.entry(part.to_owned()).or_insert(Val::Null);
        if !matches!(slot, Val::Obj(_)) {
            *slot = Val::Obj(Obj::new());
        }
        let Val::Obj(next) = slot else {
            // INFALLIBLE: the slot was made an object just above.
            return;
        };
        cur = next;
    }
    cur.insert(last.to_owned(), v);
}

/// The key a dotted path ends in: `a.b.c` gives `c`.
#[must_use]
pub fn last_segment(path: &str) -> &str {
    path.rsplit('.').next().unwrap_or(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_numbers_like_javascript() {
        let cases = [
            (0.0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (-2.5, "-2.5"),
            (0.1 + 0.2, "0.30000000000000004"),
            (1e21, "1e+21"),
            (1e20, "100000000000000000000"),
            (1.5e-7, "1.5e-7"),
            (0.000_001, "0.000001"),
            (123_456_789.125, "123456789.125"),
            (f64::NAN, "NaN"),
            (f64::NEG_INFINITY, "-Infinity"),
        ];
        for (n, text) in cases {
            assert_eq!(format_number(n), text, "{n}");
        }
    }

    #[test]
    fn coerces_text_to_numbers() {
        assert_eq!(to_num(&" 42 ".into()), 42.0);
        assert_eq!(to_num(&".5".into()), 0.5);
        assert_eq!(to_num(&"5.".into()), 5.0);
        assert!(to_num(&"0x10".into()).is_nan());
        assert!(to_num(&"1e".into()).is_nan());
        assert_eq!(to_num(&"".into()), 0.0);
    }

    #[test]
    fn orders_index_keys_first() {
        let o = obj([
            ("b", Val::Num(1.0)),
            ("2", Val::Null),
            ("1", Val::Null),
            ("01", Val::Null),
        ]);
        assert_eq!(
            stringify(&Val::Obj(o)),
            r#"{"1":null,"2":null,"b":1,"01":null}"#
        );
    }

    #[test]
    fn walks_and_writes_paths() {
        let mut o = Obj::new();
        set_path(&mut o, "a.b", Val::Num(1.0));
        set_path(&mut o, "a.b.c", Val::Num(2.0));
        assert_eq!(stringify(&Val::Obj(o.clone())), r#"{"a":{"b":{"c":2}}}"#);
        assert_eq!(to_num(get_path(&Val::Obj(o), "a.b.c")), 2.0);
    }
}
