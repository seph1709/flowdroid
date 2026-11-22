/**
 * Evaluates a parsed expression against a context of variables
 * (`$json`, `$node`, `$now`, …). Semantics follow JavaScript where that is
 * cheap to reproduce, and are simplified where JavaScript is surprising:
 * `==` is strict deep equality, member access on `null` yields `null`.
 */

import { fail } from '../errors.ts';
import { compareStrings, deepEqual, getKey, isObj, toNum, toStr, truthy, type Obj, type Val } from '../value.ts';
import type { Expr } from './ast.ts';
import { callFunction, callMethod, isNamespace } from './builtins.ts';

export function evaluate(expr: Expr, ctx: Obj): Val {
  switch (expr.kind) {
    case 'literal':
      return expr.value;
    case 'ident':
      if (!Object.hasOwn(ctx, expr.name)) fail('ExpressionError', `unknown variable ${expr.name}`);
      return getKey(ctx, expr.name);
    case 'array':
      return expr.items.map((item) => evaluate(item, ctx));
    case 'member':
      return member(evaluate(expr.object, ctx), evaluate(expr.property, ctx));
    case 'call':
      return call(expr, ctx);
    case 'unary':
      return expr.op === '!' ? !truthy(evaluate(expr.operand, ctx)) : -toNum(evaluate(expr.operand, ctx));
    case 'binary':
      return binary(expr.op, expr.left, expr.right, ctx);
    case 'conditional':
      return truthy(evaluate(expr.test, ctx)) ? evaluate(expr.then, ctx) : evaluate(expr.otherwise, ctx);
  }
}

function member(object: Val, property: Val): Val {
  if (Array.isArray(object)) {
    if (property === 'length') return object.length;
    const index = toNum(property);
    return Number.isInteger(index) && index >= 0 ? (object[index] ?? null) : null;
  }
  if (typeof object === 'string') return property === 'length' ? object.length : null;
  if (isObj(object)) return getKey(object, toStr(property));
  return null;
}

function call(expr: Extract<Expr, { kind: 'call' }>, ctx: Obj): Val {
  const { callee } = expr;
  const args = (): Val[] => expr.args.map((a) => evaluate(a, ctx));
  if (callee.kind === 'ident' && !Object.hasOwn(ctx, callee.name)) {
    return callFunction(null, callee.name, args());
  }
  if (callee.kind === 'member' && callee.property.kind === 'literal' && typeof callee.property.value === 'string') {
    const name = callee.property.value;
    const { object } = callee;
    if (object.kind === 'ident' && isNamespace(object.name) && !Object.hasOwn(ctx, object.name)) {
      return callFunction(object.name, name, args());
    }
    const receiver = evaluate(object, ctx);
    return receiver === null ? null : callMethod(receiver, name, args());
  }
  return fail('ExpressionError', 'expression is not callable');
}

function binary(op: string, leftExpr: Expr, rightExpr: Expr, ctx: Obj): Val {
  const left = evaluate(leftExpr, ctx);
  switch (op) {
    case '&&':
      return truthy(left) ? evaluate(rightExpr, ctx) : left;
    case '||':
      return truthy(left) ? left : evaluate(rightExpr, ctx);
    case '??':
      return left === null ? evaluate(rightExpr, ctx) : left;
  }
  const right = evaluate(rightExpr, ctx);
  switch (op) {
    case '==':
    case '===':
      return deepEqual(left, right);
    case '!=':
    case '!==':
      return !deepEqual(left, right);
    case '<':
      return relational(left, right, (c) => c < 0);
    case '<=':
      return relational(left, right, (c) => c <= 0);
    case '>':
      return relational(left, right, (c) => c > 0);
    case '>=':
      return relational(left, right, (c) => c >= 0);
    case '+':
      return add(left, right);
    case '-':
      return toNum(left) - toNum(right);
    case '*':
      return toNum(left) * toNum(right);
    case '/':
      return toNum(left) / toNum(right);
    default: // '%'
      return toNum(left) % toNum(right);
  }
}

/** Strings compare by code units; anything else numerically (NaN is never ordered). */
function relational(left: Val, right: Val, test: (cmp: number) => boolean): boolean {
  if (typeof left === 'string' && typeof right === 'string') return test(compareStrings(left, right));
  const a = toNum(left);
  const b = toNum(right);
  if (Number.isNaN(a) || Number.isNaN(b)) return false;
  return test(a < b ? -1 : a > b ? 1 : 0);
}

/** Numbers and booleans add; anything involving text, lists or objects concatenates. */
function add(left: Val, right: Val): Val {
  const numeric = (v: Val): boolean => v === null || typeof v === 'number' || typeof v === 'boolean';
  if (numeric(left) && numeric(right)) return toNum(left) + toNum(right);
  return toStr(left) + toStr(right);
}
