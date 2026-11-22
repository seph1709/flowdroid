/**
 * Templates are strings with `{{ expression }}` segments.
 * A template that is exactly one segment keeps the expression's type
 * (`{{ $json.count }}` stays a number); otherwise segments are spliced in as text.
 */

import { isObj, toTemplateStr, type Obj, type Val } from '../value.ts';
import { evaluate } from './evaluate.ts';
import { parseExpression } from './parser.ts';

const OPEN = '{{';
const CLOSE = '}}';

type Segment = { text: string } | { expr: string };

export function isTemplate(v: Val): v is string {
  return typeof v === 'string' && v.includes(OPEN);
}

/** Splits a template into literal text and expression sources. An unclosed `{{` is text. */
export function segments(template: string): Segment[] {
  const out: Segment[] = [];
  let rest = template;
  for (;;) {
    const open = rest.indexOf(OPEN);
    const close = open < 0 ? -1 : rest.indexOf(CLOSE, open + OPEN.length);
    if (close < 0) {
      if (rest !== '') out.push({ text: rest });
      return out;
    }
    if (open > 0) out.push({ text: rest.slice(0, open) });
    out.push({ expr: rest.slice(open + OPEN.length, close) });
    rest = rest.slice(close + CLOSE.length);
  }
}

export function renderTemplate(template: string, ctx: Obj): Val {
  const parts = segments(template);
  const only = parts.length === 1 ? parts[0] : undefined;
  if (only !== undefined && 'expr' in only) return evaluate(parseExpression(only.expr), ctx);
  return parts.map((p) => ('expr' in p ? toTemplateStr(evaluate(parseExpression(p.expr), ctx)) : p.text)).join('');
}

/** Renders a parameter value: templates are evaluated, anything else is returned as is. */
export function render(v: Val, ctx: Obj): Val {
  return isTemplate(v) ? renderTemplate(v, ctx) : v;
}

/** Parses every expression in a parameter tree; returns the first error message per template. */
export function checkTemplates(v: Val, report: (message: string) => void): void {
  if (isTemplate(v)) {
    for (const part of segments(v)) {
      if (!('expr' in part)) continue;
      try {
        parseExpression(part.expr);
      } catch (e) {
        report(e instanceof Error ? e.message : String(e));
        return;
      }
    }
  } else if (Array.isArray(v)) {
    v.forEach((item) => checkTemplates(item, report));
  } else if (isObj(v)) {
    Object.values(v).forEach((item) => checkTemplates(item, report));
  }
}
