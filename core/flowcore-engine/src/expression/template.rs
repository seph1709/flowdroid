//! Templates: strings with `{{ expression }}` segments. A template that is
//! exactly one segment keeps the expression's type; otherwise segments are
//! spliced in as text.

use super::evaluate::evaluate;
use super::parser::parse_expression;
use super::scope::Scope;
use crate::errors::Result;
use crate::value::{Val, ordered_entries, to_template_str};

const OPEN: &str = "{{";
const CLOSE: &str = "}}";

enum Segment<'a> {
    Text(&'a str),
    Expr(&'a str),
}

#[must_use]
pub fn is_template(v: &Val) -> bool {
    v.as_str().is_some_and(|s| s.contains(OPEN))
}

/// Splits a template into literal text and expression sources. An unclosed `{{` is text.
fn segments(template: &str) -> Vec<Segment<'_>> {
    let mut out = Vec::new();
    let mut rest = template;
    loop {
        let open = rest.find(OPEN);
        let close = open.and_then(|o| {
            rest[o + OPEN.len()..]
                .find(CLOSE)
                .map(|c| o + OPEN.len() + c)
        });
        let (Some(open), Some(close)) = (open, close) else {
            if !rest.is_empty() {
                out.push(Segment::Text(rest));
            }
            return out;
        };
        if open > 0 {
            out.push(Segment::Text(&rest[..open]));
        }
        out.push(Segment::Expr(&rest[open + OPEN.len()..close]));
        rest = &rest[close + CLOSE.len()..];
    }
}

pub fn render_template(template: &str, scope: &Scope<'_>) -> Result<Val> {
    let parts = segments(template);
    if let [Segment::Expr(src)] = parts.as_slice() {
        return evaluate(&parse_expression(src)?, scope);
    }
    let mut out = String::new();
    for part in parts {
        match part {
            Segment::Text(text) => out.push_str(text),
            Segment::Expr(src) => {
                out.push_str(&to_template_str(&evaluate(&parse_expression(src)?, scope)?));
            }
        }
    }
    Ok(Val::Str(out))
}

/// Renders a parameter value: templates are evaluated, anything else is returned as is.
pub fn render(v: &Val, scope: &Scope<'_>) -> Result<Val> {
    match v {
        Val::Str(s) if s.contains(OPEN) => render_template(s, scope),
        _ => Ok(v.clone()),
    }
}

/// Parses every expression in a parameter tree, reporting the first error of each template.
pub fn check_templates(v: &Val, report: &mut impl FnMut(String)) {
    match v {
        Val::Str(s) if s.contains(OPEN) => {
            for part in segments(s) {
                if let Segment::Expr(src) = part {
                    if let Err(e) = parse_expression(src) {
                        report(e.to_string());
                        return;
                    }
                }
            }
        }
        Val::Arr(items) => items.iter().for_each(|item| check_templates(item, report)),
        Val::Obj(o) => ordered_entries(o)
            .into_iter()
            .for_each(|(_, item)| check_templates(item, report)),
        _ => {}
    }
}
