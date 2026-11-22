/** Global functions (`String`, `Math.*`, `JSON.*`) and value methods. */

import { fail } from '../errors.ts';
import { parseJson } from '../json.ts';
import { deepEqual, jsTrim, stringify, toInt, toNum, toStr, truthy, type Val } from '../value.ts';

const NAMESPACES = new Set(['Math', 'JSON']);

export function isNamespace(name: string): boolean {
  return NAMESPACES.has(name);
}

/** Calls `name(args)`, or `namespace.name(args)` for `Math` and `JSON`. */
export function callFunction(namespace: string | null, name: string, args: Val[]): Val {
  const x = args[0] ?? null;
  switch (namespace === null ? name : `${namespace}.${name}`) {
    case 'String':
      return toStr(x);
    case 'Number':
      return toNum(x);
    case 'Boolean':
      return truthy(x);
    case 'Math.round':
      return round(toNum(x));
    case 'Math.floor':
      return Math.floor(toNum(x));
    case 'Math.ceil':
      return Math.ceil(toNum(x));
    case 'Math.abs':
      return Math.abs(toNum(x));
    case 'Math.min':
      return extreme(args, (candidate, best) => candidate < best, Infinity);
    case 'Math.max':
      return extreme(args, (candidate, best) => candidate > best, -Infinity);
    case 'JSON.stringify':
      return stringify(x);
    case 'JSON.parse':
      return parseJson(toStr(x), 'JSON.parse argument', 'ExpressionError');
    default:
      return fail('ExpressionError', `unknown function ${namespace === null ? '' : `${namespace}.`}${name}`);
  }
}

export function callMethod(receiver: Val, name: string, args: Val[]): Val {
  if (name === 'toString') return toStr(receiver);
  if (typeof receiver === 'string') return stringMethod(receiver, name, args);
  if (Array.isArray(receiver)) return arrayMethod(receiver, name, args);
  return fail('ExpressionError', `unknown method ${name}`);
}

function stringMethod(s: string, name: string, args: Val[]): Val {
  const text = (i: number): string => toStr(args[i] ?? null);
  switch (name) {
    case 'toUpperCase':
      return s.toUpperCase();
    case 'toLowerCase':
      return s.toLowerCase();
    case 'trim':
      return jsTrim(s);
    case 'includes':
      return s.includes(text(0));
    case 'startsWith':
      return s.startsWith(text(0));
    case 'endsWith':
      return s.endsWith(text(0));
    case 'indexOf':
      return s.indexOf(text(0));
    case 'split':
      return split(s, args);
    case 'replace':
      return replaceFirst(s, text(0), text(1));
    case 'replaceAll':
      return text(0) === '' ? s : s.split(text(0)).join(text(1));
    case 'slice': {
      // A cut through a surrogate pair leaves half a character; it becomes U+FFFD
      // so every port (and every UTF-8 host) sees the same well-formed text.
      const [start, end] = sliceBounds(s.length, args);
      return s.slice(start, end).toWellFormed();
    }
    default:
      return fail('ExpressionError', `unknown method ${name}`);
  }
}

function arrayMethod(list: Val[], name: string, args: Val[]): Val {
  const x = args[0] ?? null;
  switch (name) {
    case 'includes':
      return list.some((item) => deepEqual(item, x));
    case 'indexOf':
      return list.findIndex((item) => deepEqual(item, x));
    case 'join': {
      const separator = args.length > 0 ? toStr(x) : ',';
      return list.map((item) => (item === null ? '' : toStr(item))).join(separator);
    }
    case 'slice': {
      const [start, end] = sliceBounds(list.length, args);
      return list.slice(start, end);
    }
    case 'first':
      return list[0] ?? null;
    case 'last':
      return list[list.length - 1] ?? null;
    default:
      return fail('ExpressionError', `unknown method ${name}`);
  }
}

/** Rounds half up (toward +Infinity), as `Math.round` does. */
function round(n: number): number {
  const floor = Math.floor(n);
  return n - floor >= 0.5 ? floor + 1 : floor;
}

/** The best number under `better`; any NaN argument makes the result NaN. */
function extreme(args: Val[], better: (candidate: number, best: number) => boolean, start: number): number {
  let best = start;
  for (const arg of args) {
    const n = toNum(arg);
    if (Number.isNaN(n)) return NaN;
    if (better(n, best)) best = n;
  }
  return best;
}

/** No separator: the whole string. Empty separator: one entry per code point. */
function split(s: string, args: Val[]): Val[] {
  const separator = args[0] ?? null;
  if (separator === null) return [s];
  const sep = toStr(separator);
  return sep === '' ? Array.from(s) : s.split(sep);
}

function replaceFirst(s: string, search: string, replacement: string): string {
  const at = s.indexOf(search);
  return at < 0 ? s : s.slice(0, at) + replacement + s.slice(at + search.length);
}

/** `slice(start, end)` bounds: negative counts from the end, clamped to `[0, length]`. */
function sliceBounds(length: number, args: Val[]): [number, number] {
  const resolve = (v: Val | undefined, fallback: number): number => {
    if (v === undefined || v === null) return fallback;
    const n = toInt(v);
    return n < 0 ? Math.max(length + n, 0) : Math.min(n, length);
  };
  return [resolve(args[0], 0), resolve(args[1], length)];
}
