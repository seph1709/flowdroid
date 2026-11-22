//! Global functions (`String`, `Math.*`, `JSON.*`) and value methods.

use crate::errors::{ErrorKind, Result, fail};
use crate::json::parse_json;
use crate::value::{
    NULL, Val, deep_equal, js_trim, stringify, to_int, to_num, to_str, truthy, utf16_len,
};

#[must_use]
pub fn is_namespace(name: &str) -> bool {
    matches!(name, "Math" | "JSON")
}

fn arg(args: &[Val], i: usize) -> &Val {
    args.get(i).unwrap_or(&NULL)
}

/// Calls `name(args)`, or `namespace.name(args)` for `Math` and `JSON`.
pub fn call_function(namespace: Option<&str>, name: &str, args: &[Val]) -> Result<Val> {
    let x = arg(args, 0);
    let qualified = namespace.map_or_else(|| name.to_owned(), |ns| format!("{ns}.{name}"));
    Ok(match qualified.as_str() {
        "String" => Val::Str(to_str(x)),
        "Number" => Val::Num(to_num(x)),
        "Boolean" => Val::Bool(truthy(x)),
        "Math.round" => Val::Num(round(to_num(x))),
        "Math.floor" => Val::Num(to_num(x).floor()),
        "Math.ceil" => Val::Num(to_num(x).ceil()),
        "Math.abs" => Val::Num(to_num(x).abs()),
        "Math.min" => Val::Num(extreme(
            args,
            |candidate, best| candidate < best,
            f64::INFINITY,
        )),
        "Math.max" => Val::Num(extreme(
            args,
            |candidate, best| candidate > best,
            f64::NEG_INFINITY,
        )),
        "JSON.stringify" => Val::Str(stringify(x)),
        "JSON.parse" => parse_json(&to_str(x), "JSON.parse argument", ErrorKind::Expression)?,
        _ => {
            return fail(
                ErrorKind::Expression,
                format!("unknown function {qualified}"),
            );
        }
    })
}

pub fn call_method(receiver: &Val, name: &str, args: &[Val]) -> Result<Val> {
    if name == "toString" {
        return Ok(Val::Str(to_str(receiver)));
    }
    match receiver {
        Val::Str(s) => string_method(s, name, args),
        Val::Arr(list) => array_method(list, name, args),
        _ => unknown_method(name),
    }
}

fn unknown_method<T>(name: &str) -> Result<T> {
    fail(ErrorKind::Expression, format!("unknown method {name}"))
}

fn string_method(s: &str, name: &str, args: &[Val]) -> Result<Val> {
    let text = |i: usize| to_str(arg(args, i));
    Ok(match name {
        "toUpperCase" => Val::Str(s.to_uppercase()),
        "toLowerCase" => Val::Str(s.to_lowercase()),
        "trim" => Val::from(js_trim(s)),
        "includes" => Val::Bool(s.contains(text(0).as_str())),
        "startsWith" => Val::Bool(s.starts_with(text(0).as_str())),
        "endsWith" => Val::Bool(s.ends_with(text(0).as_str())),
        "indexOf" => Val::Num(
            s.find(text(0).as_str())
                .map_or(-1.0, |at| utf16_len(&s[..at]) as f64),
        ),
        "split" => split(s, args),
        "replace" => Val::Str(replace_first(s, &text(0), &text(1))),
        "replaceAll" => {
            let search = text(0);
            Val::Str(if search.is_empty() {
                s.to_owned()
            } else {
                s.replace(search.as_str(), &text(1))
            })
        }
        "slice" => {
            let units: Vec<u16> = s.encode_utf16().collect();
            let (start, end) = slice_bounds(units.len(), args);
            Val::Str(String::from_utf16_lossy(
                units.get(start..end).unwrap_or_default(),
            ))
        }
        _ => return unknown_method(name),
    })
}

fn array_method(list: &[Val], name: &str, args: &[Val]) -> Result<Val> {
    let x = arg(args, 0);
    Ok(match name {
        "includes" => Val::Bool(list.iter().any(|item| deep_equal(item, x))),
        "indexOf" => Val::Num(
            list.iter()
                .position(|item| deep_equal(item, x))
                .map_or(-1.0, |i| i as f64),
        ),
        "join" => {
            let separator = if args.is_empty() {
                ",".to_owned()
            } else {
                to_str(x)
            };
            let parts: Vec<String> = list
                .iter()
                .map(|item| {
                    if item.is_null() {
                        String::new()
                    } else {
                        to_str(item)
                    }
                })
                .collect();
            Val::Str(parts.join(&separator))
        }
        "slice" => {
            let (start, end) = slice_bounds(list.len(), args);
            Val::Arr(list.get(start..end).unwrap_or_default().to_vec())
        }
        "first" => list.first().cloned().unwrap_or_default(),
        "last" => list.last().cloned().unwrap_or_default(),
        _ => return unknown_method(name),
    })
}

/// Rounds half up (toward +Infinity), as `Math.round` does.
fn round(n: f64) -> f64 {
    let floor = n.floor();
    if n - floor >= 0.5 { floor + 1.0 } else { floor }
}

/// The best number under `better`; any NaN argument makes the result NaN.
fn extreme(args: &[Val], better: impl Fn(f64, f64) -> bool, start: f64) -> f64 {
    let mut best = start;
    for arg in args {
        let n = to_num(arg);
        if n.is_nan() {
            return f64::NAN;
        }
        if better(n, best) {
            best = n;
        }
    }
    best
}

/// No separator: the whole string. Empty separator: one entry per code point.
fn split(s: &str, args: &[Val]) -> Val {
    let separator = arg(args, 0);
    if separator.is_null() {
        return Val::Arr(vec![Val::from(s)]);
    }
    let sep = to_str(separator);
    let parts: Vec<Val> = if sep.is_empty() {
        s.chars().map(|c| Val::Str(c.to_string())).collect()
    } else {
        s.split(sep.as_str()).map(Val::from).collect()
    };
    Val::Arr(parts)
}

fn replace_first(s: &str, search: &str, replacement: &str) -> String {
    match s.find(search) {
        Some(at) => format!("{}{replacement}{}", &s[..at], &s[at + search.len()..]),
        None => s.to_owned(),
    }
}

/// `slice(start, end)` bounds: negative counts from the end, clamped to `[0, length]`.
fn slice_bounds(length: usize, args: &[Val]) -> (usize, usize) {
    let len = length as f64;
    let resolve = |v: Option<&Val>, fallback: f64| -> f64 {
        match v {
            None | Some(Val::Null) => fallback,
            Some(v) => {
                let n = to_int(v);
                if n < 0.0 {
                    (len + n).max(0.0)
                } else {
                    n.min(len)
                }
            }
        }
    };
    let start = resolve(args.first(), 0.0) as usize;
    let end = resolve(args.get(1), len) as usize;
    (start, end.max(start))
}
