//! Evaluates a parsed expression; semantics are documented in `evaluate.ts`.

use std::cmp::Ordering;

use super::ast::{BinaryOp, Expr, LogicalOp, UnaryOp};
use super::builtins::{call_function, call_method, is_namespace};
use super::scope::Scope;
use crate::errors::{ErrorKind, Result, fail};
use crate::value::{Val, compare_strings, deep_equal, to_num, to_str, truthy, utf16_len};

pub fn evaluate(expr: &Expr, scope: &Scope<'_>) -> Result<Val> {
    match expr {
        Expr::Literal(v) => Ok(v.clone()),
        Expr::Ident(name) => match scope.get(name) {
            Some(v) => Ok(v.clone()),
            None => fail(ErrorKind::Expression, format!("unknown variable {name}")),
        },
        Expr::Array(items) => items
            .iter()
            .map(|item| evaluate(item, scope))
            .collect::<Result<Vec<_>>>()
            .map(Val::Arr),
        Expr::Member { object, property } => {
            let object = evaluate(object, scope)?;
            let property = evaluate(property, scope)?;
            Ok(member(object, &property))
        }
        Expr::Call { callee, args } => call(callee, args, scope),
        Expr::Unary {
            op: UnaryOp::Not,
            operand,
        } => Ok(Val::Bool(!truthy(&evaluate(operand, scope)?))),
        Expr::Unary {
            op: UnaryOp::Neg,
            operand,
        } => Ok(Val::Num(-to_num(&evaluate(operand, scope)?))),
        Expr::Logical { op, left, right } => logical(*op, left, right, scope),
        Expr::Binary { op, left, right } => Ok(binary(
            *op,
            &evaluate(left, scope)?,
            &evaluate(right, scope)?,
        )),
        Expr::Conditional {
            test,
            then,
            otherwise,
        } => {
            if truthy(&evaluate(test, scope)?) {
                evaluate(then, scope)
            } else {
                evaluate(otherwise, scope)
            }
        }
    }
}

/// Reads `object[property]`, taking the object so no copy of the result is needed.
fn member(object: Val, property: &Val) -> Val {
    match object {
        Val::Arr(list) if property.is_str("length") => Val::from(list.len()),
        Val::Arr(list) => {
            let index = to_num(property);
            if index.fract() == 0.0 && index >= 0.0 && index < list.len() as f64 {
                list.into_iter().nth(index as usize).unwrap_or_default()
            } else {
                Val::Null
            }
        }
        Val::Str(s) if property.is_str("length") => Val::from(utf16_len(&s)),
        Val::Obj(mut o) => o.swap_remove(to_str(property).as_str()).unwrap_or_default(),
        _ => Val::Null,
    }
}

fn call(callee: &Expr, args: &[Expr], scope: &Scope<'_>) -> Result<Val> {
    let eval_args = || {
        args.iter()
            .map(|a| evaluate(a, scope))
            .collect::<Result<Vec<_>>>()
    };
    match callee {
        Expr::Ident(name) if !scope.has(name) => call_function(None, name, &eval_args()?),
        Expr::Member { object, property } => {
            let Expr::Literal(Val::Str(name)) = property.as_ref() else {
                return fail(ErrorKind::Expression, "expression is not callable");
            };
            if let Expr::Ident(namespace) = object.as_ref() {
                if is_namespace(namespace) && !scope.has(namespace) {
                    return call_function(Some(namespace), name, &eval_args()?);
                }
            }
            let receiver = evaluate(object, scope)?;
            if receiver.is_null() {
                return Ok(Val::Null);
            }
            call_method(&receiver, name, &eval_args()?)
        }
        _ => fail(ErrorKind::Expression, "expression is not callable"),
    }
}

/// `&&`, `||` and `??` return one of their operands and skip the right one when they can.
fn logical(op: LogicalOp, left: &Expr, right: &Expr, scope: &Scope<'_>) -> Result<Val> {
    let left = evaluate(left, scope)?;
    let take_left = match op {
        LogicalOp::And => !truthy(&left),
        LogicalOp::Or => truthy(&left),
        LogicalOp::Nullish => !left.is_null(),
    };
    if take_left {
        Ok(left)
    } else {
        evaluate(right, scope)
    }
}

fn binary(op: BinaryOp, left: &Val, right: &Val) -> Val {
    match op {
        BinaryOp::Eq => Val::Bool(deep_equal(left, right)),
        BinaryOp::Ne => Val::Bool(!deep_equal(left, right)),
        BinaryOp::Lt => Val::Bool(relational(left, right).is_some_and(Ordering::is_lt)),
        BinaryOp::Le => Val::Bool(relational(left, right).is_some_and(Ordering::is_le)),
        BinaryOp::Gt => Val::Bool(relational(left, right).is_some_and(Ordering::is_gt)),
        BinaryOp::Ge => Val::Bool(relational(left, right).is_some_and(Ordering::is_ge)),
        BinaryOp::Add => add(left, right),
        BinaryOp::Sub => Val::Num(to_num(left) - to_num(right)),
        BinaryOp::Mul => Val::Num(to_num(left) * to_num(right)),
        BinaryOp::Div => Val::Num(to_num(left) / to_num(right)),
        BinaryOp::Rem => Val::Num(to_num(left) % to_num(right)),
    }
}

/// Strings compare by code units; anything else numerically (`None` when either is NaN).
fn relational(left: &Val, right: &Val) -> Option<Ordering> {
    if let (Val::Str(a), Val::Str(b)) = (left, right) {
        return Some(compare_strings(a, b));
    }
    to_num(left).partial_cmp(&to_num(right))
}

/// Numbers and booleans add; anything involving text, lists or objects concatenates.
fn add(left: &Val, right: &Val) -> Val {
    let numeric = |v: &Val| matches!(v, Val::Null | Val::Num(_) | Val::Bool(_));
    if numeric(left) && numeric(right) {
        Val::Num(to_num(left) + to_num(right))
    } else {
        Val::Str(to_str(left) + &to_str(right))
    }
}
