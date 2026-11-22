//! Conditions used by the If, Filter and Switch nodes.

use std::cmp::Ordering;

use crate::errors::{ErrorKind, Result, fail};
use crate::expression::{Scope, render};
use crate::value::{
    Obj, Val, compare_strings, deep_equal, get_key, is_empty, to_num, to_str, truthy,
};

/// True when the conditions hold for one item; `combine` is `and` (default) or `or`.
/// Every condition is evaluated, so an error in any of them surfaces.
pub fn matches_all(conditions: &Val, combine: &Val, scope: &Scope<'_>) -> Result<bool> {
    let list = conditions.as_arr().map_or(&[][..], Vec::as_slice);
    let results = list
        .iter()
        .enumerate()
        .map(|(i, c)| matches(c, scope, i))
        .collect::<Result<Vec<_>>>()?;
    Ok(if combine.is_str("or") {
        results.contains(&true)
    } else {
        results.iter().all(|r| *r)
    })
}

pub fn matches(condition: &Val, scope: &Scope<'_>, index: usize) -> Result<bool> {
    let Val::Obj(condition) = condition else {
        return fail(
            ErrorKind::Node,
            format!("condition {index} must be an object"),
        );
    };
    let left = render(get_key(condition, "left"), scope)?;
    let right = render(get_key(condition, "right"), scope)?;
    let op = match get_key(condition, "op") {
        Val::Null => "equals".to_owned(),
        op => to_str(op),
    };
    compare(&op, &left, &right)
}

fn compare(op: &str, left: &Val, right: &Val) -> Result<bool> {
    Ok(match op {
        "equals" => loose_equal(left, right),
        "notEquals" => !loose_equal(left, right),
        "contains" => contains(left, right),
        "notContains" => !contains(left, right),
        "startsWith" => to_str(left).starts_with(&to_str(right)),
        "endsWith" => to_str(left).ends_with(&to_str(right)),
        "gt" => order(left, right).is_some_and(Ordering::is_gt),
        "gte" => order(left, right).is_some_and(Ordering::is_ge),
        "lt" => order(left, right).is_some_and(Ordering::is_lt),
        "lte" => order(left, right).is_some_and(Ordering::is_le),
        "isEmpty" => is_empty(left),
        "isNotEmpty" => !is_empty(left),
        "isTrue" => truthy(left),
        "isFalse" => !truthy(left),
        _ => return fail(ErrorKind::Node, format!("unknown operator {op}")),
    })
}

fn is_primitive(v: &Val) -> bool {
    matches!(v, Val::Str(_) | Val::Num(_) | Val::Bool(_))
}

/// Deep equality, plus text equality for primitives, so `5` equals `"5"`.
#[must_use]
pub fn loose_equal(a: &Val, b: &Val) -> bool {
    deep_equal(a, b) || (is_primitive(a) && is_primitive(b) && to_str(a) == to_str(b))
}

fn contains(haystack: &Val, needle: &Val) -> bool {
    match haystack {
        Val::Arr(list) => list.iter().any(|x| loose_equal(x, needle)),
        _ => to_str(haystack).contains(&to_str(needle)),
    }
}

/// Numeric order when both sides are numbers; text order for two non-numeric strings.
fn order(left: &Val, right: &Val) -> Option<Ordering> {
    let (a, b) = (to_num(left), to_num(right));
    if !a.is_nan() && !b.is_nan() {
        return a.partial_cmp(&b);
    }
    match (left, right) {
        (Val::Str(x), Val::Str(y)) => Some(compare_strings(x, y)),
        _ => None,
    }
}

/// The `conditions` and `combine` parameters shared by If and Filter.
#[must_use]
pub fn as_conditions(params: &Obj) -> (&Val, &Val) {
    (get_key(params, "conditions"), get_key(params, "combine"))
}
