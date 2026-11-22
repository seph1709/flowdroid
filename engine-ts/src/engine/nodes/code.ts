/**
 * Code: runs JavaScript (Node.js) or Python that the user wrote. The engine
 * cannot run it itself; the host runs it in FlowDroid's Ubuntu and returns
 * what it returned.
 */

import { fail } from '../../errors.ts';
import { getKey, isObj, type Obj, type Val } from '../../value.ts';
import type { Item } from '../context.ts';
import { checkEffectError, itemsOf, paramNumber, paramText, type NodeResult, type NodeRun, type NodeSpec } from './spec.ts';

const LANGUAGES = ['javascript', 'python'];
const MODES = ['allItems', 'eachItem'];

const DEFAULT_CODE = `// items: the input items. Return the items to output.
// In Python: same names, e.g. return [{**item, "checked": True} for item in items]
return items.map((item) => ({ ...item, checked: true }));`;

/** What the code returned, as items: objects as they are, other values as `{ value }`, null as nothing. */
function toItems(v: Val): Item[] {
  if (v === null) return [];
  const one = (x: Val): Item => (isObj(x) ? x : { value: x });
  return Array.isArray(v) ? v.map(one) : [one(v)];
}

function run(run: NodeRun): NodeResult {
  const language = paramText(run, 'language', 0);
  if (!LANGUAGES.includes(language)) fail('NodeError', `unknown language ${language}`);
  const mode = paramText(run, 'mode', 0);
  if (!MODES.includes(mode)) fail('NodeError', `unknown mode ${mode}`);
  // The code is not a template: `{{ }}` inside it is the language's own syntax.
  const code = getKey(run.params, 'code');
  if (typeof code !== 'string' || code.trim() === '') fail('NodeError', 'code is empty');
  const timeout = paramNumber(run, 'timeout', 0);
  const timeoutMs = (timeout > 0 ? timeout : 60) * 1000;
  return { effect: { type: 'code', language, mode, code, items: itemsOf(run), timeoutMs } };
}

function resume(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const results = getKey(result, 'results');
  if (paramText(run, 'mode', 0) === 'allItems') return [toItems(results)];
  const items = itemsOf(run);
  if (!Array.isArray(results) || results.length !== items.length) {
    fail('NodeError', `expected ${items.length} code results`);
  }
  return [results.flatMap(toItems)];
}

export const codeNodes: NodeSpec[] = [
  {
    type: 'core.code',
    label: 'Code',
    group: 'data',
    description: 'Runs your JavaScript or Python on the items (in FlowDroid’s Ubuntu) and outputs what it returns.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'language', label: 'Language', kind: 'select', default: 'javascript', options: LANGUAGES },
      { key: 'mode', label: 'Run', kind: 'select', default: 'allItems', options: MODES, hint: 'all items once, or once per item (as `item`)' },
      { key: 'code', label: 'Code', kind: 'code', default: DEFAULT_CODE },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: 60 },
    ],
    run,
    resume,
  },
];
