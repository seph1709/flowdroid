/**
 * The value model shared by expressions, items and node parameters.
 *
 * Values are plain JSON. `null` doubles as "undefined": a missing key, an
 * out-of-range index and member access on `null` all produce `null`.
 * Every rule here is spelled out explicitly (rather than leaning on
 * JavaScript coercion) so the Rust port can reproduce it exactly.
 */

export type Val = null | boolean | number | string | Val[] | Obj;
export type Obj = { [key: string]: Val };

/** Whitespace removed by `String.prototype.trim`, listed for the Rust port. */
const WS = String.raw`[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]`;
const WHITESPACE = new RegExp(`^${WS}+|${WS}+$`, 'g');

/** A decimal number literal, the only string form `toNum` accepts. */
const DECIMAL = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;

export function isObj(v: Val | undefined): v is Obj {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Own-property lookup, so keys such as `constructor` never reach the prototype. */
export function getKey(o: Obj, key: string): Val {
  return Object.hasOwn(o, key) ? (o[key] ?? null) : null;
}

/** Defines an own property, so `__proto__` is stored as data, not a prototype. */
export function setKey(o: Obj, key: string, v: Val): void {
  Object.defineProperty(o, key, { value: v, writable: true, enumerable: true, configurable: true });
}

export function clone(v: Val): Val {
  if (Array.isArray(v)) return v.map(clone);
  if (isObj(v)) {
    const out: Obj = {};
    for (const key of Object.keys(v)) setKey(out, key, clone(getKey(v, key)));
    return out;
  }
  return v;
}

/** Entries in JavaScript property order (array-index keys first, then insertion order). */
export function ordered(o: Obj): [string, Val][] {
  return Object.keys(o).map((k): [string, Val] => [k, getKey(o, k)]);
}

export function cloneObj(o: Obj): Obj {
  return clone(o) as Obj;
}

/** Structural equality; `NaN` is never equal to itself. */
export function deepEqual(a: Val, b: Val): boolean {
  if (Array.isArray(a)) {
    return Array.isArray(b) && a.length === b.length && a.every((x, i) => deepEqual(x, b[i] ?? null));
  }
  if (isObj(a)) {
    if (!isObj(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length
      && keys.every((k) => Object.hasOwn(b, k) && deepEqual(getKey(a, k), getKey(b, k)));
  }
  return a === b;
}

export function truthy(v: Val): boolean {
  if (v === null) return false;
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0 && !Number.isNaN(v);
  if (typeof v === 'string') return v !== '';
  return true;
}

export function jsTrim(s: string): string {
  return s.replace(WHITESPACE, '');
}

export function toNum(v: Val): number {
  if (v === null) return 0;
  if (typeof v === 'boolean') return v ? 1 : 0;
  if (typeof v === 'number') return v;
  if (typeof v === 'string') {
    const s = jsTrim(v);
    if (s === '') return 0;
    return DECIMAL.test(s) ? Number(s) : NaN;
  }
  return NaN;
}

/** `ToIntegerOrInfinity`: NaN becomes 0, everything else truncates. */
export function toInt(v: Val): number {
  const n = toNum(v);
  return Number.isNaN(n) ? 0 : Math.trunc(n) + 0;
}

export function formatNumber(n: number): string {
  return String(n);
}

/** Text form of a value: arrays and objects become compact JSON. */
export function toStr(v: Val): string {
  if (v === null) return 'null';
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return formatNumber(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  return stringify(v);
}

/** Text spliced into a template: like `toStr`, but `null` renders as nothing. */
export function toTemplateStr(v: Val): string {
  return v === null ? '' : toStr(v);
}

export function stringify(v: Val): string {
  return JSON.stringify(v);
}

/** Orders strings by UTF-16 code units, as JavaScript's `<` does. */
export function compareStrings(a: string, b: string): number {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

export function isEmpty(v: Val): boolean {
  if (v === null || v === '') return true;
  if (Array.isArray(v)) return v.length === 0;
  if (isObj(v)) return Object.keys(v).length === 0;
  return false;
}

/** Reads a dotted path such as `user.tags.0`; numeric parts index arrays. */
export function getPath(root: Val, path: string): Val {
  let cur: Val = root;
  for (const part of path.split('.')) {
    if (Array.isArray(cur) && /^\d+$/.test(part)) cur = cur[Number(part)] ?? null;
    else if (isObj(cur)) cur = getKey(cur, part);
    else return null;
  }
  return cur;
}

/** Writes a dotted path, creating (or replacing non-object) parents as needed. */
export function setPath(root: Obj, path: string, v: Val): void {
  const parts = path.split('.');
  let cur = root;
  for (const part of parts.slice(0, -1)) {
    const next = getKey(cur, part);
    if (isObj(next)) {
      cur = next;
    } else {
      const created: Obj = {};
      setKey(cur, part, created);
      cur = created;
    }
  }
  setKey(cur, parts[parts.length - 1] ?? '', v);
}

/** The key a dotted path ends in: `a.b.c` gives `c`. */
export function lastSegment(path: string): string {
  const parts = path.split('.');
  return parts[parts.length - 1] ?? '';
}
