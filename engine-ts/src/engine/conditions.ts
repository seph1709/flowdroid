/** Conditions used by the IF, Filter and Switch nodes. */

import { fail } from '../errors.ts';
import { render } from '../expression/template.ts';
import {
  compareStrings, deepEqual, getKey, isEmpty, isObj, toNum, toStr, truthy, type Obj, type Val,
} from '../value.ts';

export const OPERATORS = [
  'equals', 'notEquals', 'contains', 'notContains', 'startsWith', 'endsWith',
  'gt', 'gte', 'lt', 'lte', 'isEmpty', 'isNotEmpty', 'isTrue', 'isFalse',
] as const;

/** True when the conditions hold for one item; `combine` is `and` (default) or `or`. */
export function matchesAll(conditions: Val, combine: Val, ctx: Obj): boolean {
  const list = Array.isArray(conditions) ? conditions : [];
  const results = list.map((c, i) => matches(c, ctx, i));
  return combine === 'or' ? results.some(Boolean) : results.every(Boolean);
}

export function matches(condition: Val, ctx: Obj, index: number): boolean {
  if (!isObj(condition)) fail('NodeError', `condition ${index} must be an object`);
  const left = render(getKey(condition, 'left'), ctx);
  const right = render(getKey(condition, 'right'), ctx);
  const op = getKey(condition, 'op') ?? 'equals';
  return compare(toStr(op), left, right);
}

function compare(op: string, left: Val, right: Val): boolean {
  switch (op) {
    case 'equals':
      return looseEqual(left, right);
    case 'notEquals':
      return !looseEqual(left, right);
    case 'contains':
      return contains(left, right);
    case 'notContains':
      return !contains(left, right);
    case 'startsWith':
      return toStr(left).startsWith(toStr(right));
    case 'endsWith':
      return toStr(left).endsWith(toStr(right));
    case 'gt':
      return order(left, right, (c) => c > 0);
    case 'gte':
      return order(left, right, (c) => c >= 0);
    case 'lt':
      return order(left, right, (c) => c < 0);
    case 'lte':
      return order(left, right, (c) => c <= 0);
    case 'isEmpty':
      return isEmpty(left);
    case 'isNotEmpty':
      return !isEmpty(left);
    case 'isTrue':
      return truthy(left);
    case 'isFalse':
      return !truthy(left);
    default:
      return fail('NodeError', `unknown operator ${op}`);
  }
}

const isPrimitive = (v: Val): boolean => typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean';

/** Deep equality, plus text equality for primitives, so `5` equals `"5"`. */
export function looseEqual(a: Val, b: Val): boolean {
  return deepEqual(a, b) || (isPrimitive(a) && isPrimitive(b) && toStr(a) === toStr(b));
}

function contains(haystack: Val, needle: Val): boolean {
  if (Array.isArray(haystack)) return haystack.some((x) => looseEqual(x, needle));
  return toStr(haystack).includes(toStr(needle));
}

/** Numeric order when both sides are numbers; text order for two non-numeric strings. */
function order(left: Val, right: Val, test: (cmp: number) => boolean): boolean {
  const a = toNum(left);
  const b = toNum(right);
  if (!Number.isNaN(a) && !Number.isNaN(b)) return test(a < b ? -1 : a > b ? 1 : 0);
  if (typeof left === 'string' && typeof right === 'string') return test(compareStrings(left, right));
  return false;
}
