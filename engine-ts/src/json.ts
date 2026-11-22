import { fail, type ErrorKind } from './errors.ts';
import { isObj, type Val } from './value.ts';

/** Deeper documents are rejected so recursion stays bounded in every port. */
export const MAX_DEPTH = 64;

/** Parses untrusted JSON; `what` names the argument in the error message. */
export function parseJson(text: string, what: string, kind: ErrorKind = 'InputError'): Val {
  let parsed: Val;
  try {
    parsed = JSON.parse(text) as Val;
  } catch {
    fail(kind, `${what} is not valid JSON`);
  }
  if (depthOf(parsed, 0) > MAX_DEPTH) fail(kind, `${what} is nested too deeply`);
  return parsed;
}

/** Nesting depth, stopping as soon as it passes `MAX_DEPTH`. */
function depthOf(v: Val, depth: number): number {
  if (depth > MAX_DEPTH) return depth;
  let children: Val[] = [];
  if (Array.isArray(v)) children = v;
  else if (isObj(v)) children = Object.values(v);
  let max = depth;
  for (const child of children) {
    max = Math.max(max, depthOf(child, depth + 1));
    if (max > MAX_DEPTH) break;
  }
  return max;
}
