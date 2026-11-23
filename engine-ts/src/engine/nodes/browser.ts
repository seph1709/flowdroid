/**
 * Browser: drives the phone's in-app browser (Android WebView, with the logins
 * saved in FlowDroid) through a short script per item:
 *   open https://…, click <target>, type <target> <text>, press Enter,
 *   wait <seconds> | wait for <target>, extract [all] <name> <selector> [@attr],
 *   scroll [target], back, screenshot [name], js <code>
 *
 * The host parses and runs the script; the node only renders it per item:
 *   { type: 'browser', runs: [{ url, steps }], visible, fast, timeoutMs }
 *   → { results: [{ url, title, data, screenshots } | { error }] }
 */

import { fail } from '../../errors.ts';
import { cloneObj, getKey, isObj, setKey, toNum, type Obj } from '../../value.ts';
import type { Item } from '../context.ts';
import { checkEffectError, itemsOf, paramText, paramValue, type NodeRun, type NodeSpec } from './spec.ts';

function run(run: NodeRun): { effect: Obj } {
  const runs = itemsOf(run).map((_, i) => {
    const url = paramText(run, 'url', i);
    if (!/^https?:\/\//.test(url)) fail('NodeError', 'the URL must start with http:// or https://');
    return { url, steps: paramText(run, 'steps', i) };
  });
  const timeout = toNum(paramValue(run, 'timeout', 0));
  return {
    effect: {
      type: 'browser',
      runs,
      visible: getKey(run.params, 'visible') === true,
      fast: getKey(run.params, 'fast') === true,
      timeoutMs: (timeout >= 1 ? timeout : 1) * 1000,
    },
  };
}

function resume(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const results = getKey(result, 'results');
  if (!Array.isArray(results)) return fail('NodeError', 'the browser returned no result');
  const field = paramText(run, 'field', 0);
  return [itemsOf(run).map((item, i) => {
    const r = results[i] ?? null;
    if (!isObj(r)) return fail('NodeError', 'the browser returned no result');
    const failed = getKey(r, 'error');
    if (typeof failed === 'string') fail('NodeError', `Browser: ${failed}`);
    const copy = cloneObj(item);
    setKey(copy, field, r);
    return copy;
  })];
}

export const browserNodes: NodeSpec[] = [
  {
    type: 'browser.run',
    label: 'Browser',
    group: 'network',
    description: 'Opens a page in the phone’s browser (with your saved logins) and clicks, types and reads it, step by step.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'url', label: 'Start at', kind: 'text', default: 'https://', hint: 'the page to open first' },
      {
        key: 'steps', label: 'Steps', kind: 'code', default: 'extract heading h1',
        hint: 'one per line: click, type, press, wait, extract, scroll, back, screenshot, js',
      },
      { key: 'visible', label: 'Show the browser while it runs', kind: 'boolean', default: false },
      { key: 'fast', label: 'Fast mode (skip images, fonts and video)', kind: 'boolean', default: true },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: 60 },
      { key: 'field', label: 'Output field', kind: 'text', default: 'browser' },
    ],
    run,
    resume,
  },
];
