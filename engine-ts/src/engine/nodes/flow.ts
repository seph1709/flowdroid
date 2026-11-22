/** Nodes that route items: branching, filtering, merging and pausing. */

import { fail } from '../../errors.ts';
import { cloneObj, getKey, setKey, toStr, type Obj } from '../../value.ts';
import { matches, matchesAll } from '../conditions.ts';
import type { Item } from '../context.ts';
import {
  ctxFor, itemsOf, paramNumber, paramValue, passThrough, resumePassThrough, rows, type NodeRun, type NodeSpec, type ParamSpec,
} from './spec.ts';

const conditionParams: ParamSpec[] = [
  { key: 'conditions', label: 'Conditions', kind: 'conditions', default: [] },
  { key: 'combine', label: 'Combine', kind: 'select', default: 'and', options: ['and', 'or'] },
];

function partition(run: NodeRun): [Item[], Item[]] {
  const kept: Item[] = [];
  const rejected: Item[] = [];
  itemsOf(run).forEach((item, i) => {
    const ok = matchesAll(getKey(run.params, 'conditions'), getKey(run.params, 'combine'), ctxFor(run, i));
    (ok ? kept : rejected).push(item);
  });
  return [kept, rejected];
}

function routeByRules(run: NodeRun): Item[][] {
  const rules = rows(run, 'rules');
  const fallback = getKey(run.params, 'fallback') === true;
  const outputs: Item[][] = Array.from({ length: rules.length + (fallback ? 1 : 0) }, () => []);
  itemsOf(run).forEach((item, i) => {
    const ctx = ctxFor(run, i);
    const hit = rules.findIndex((rule, r) => matches(rule, ctx, r));
    const target = hit >= 0 ? hit : fallback ? rules.length : -1;
    outputs[target]?.push(item);
  });
  return outputs;
}

/** Merge waits for every connected input; the executor hands it all of them at once. */
function merge(run: NodeRun): Item[] {
  const [first = [], second = []] = run.inputs;
  const mode = toStr(getKey(run.params, 'mode'));
  switch (mode) {
    case 'append':
      return [...first, ...second];
    case 'combineByIndex':
      return first.slice(0, Math.min(first.length, second.length)).map((a, i) => {
        const out = cloneObj(a);
        const b = cloneObj(second[i] ?? {});
        for (const key of Object.keys(b)) setKey(out, key, getKey(b, key));
        return out;
      });
    case 'chooseBranch':
      return getKey(run.params, 'output') === 'input2' ? second : first;
    default:
      return fail('NodeError', `unknown merge mode ${mode}`);
  }
}

function respondEffect(run: NodeRun): Obj {
  const body = getKey(run.params, 'body') === '' ? itemsOf(run) : paramValue(run, 'body', 0);
  return {
    type: 'respond',
    status: paramNumber(run, 'status', 0),
    contentType: toStr(paramValue(run, 'contentType', 0)),
    body,
  };
}

export const flowNodes: NodeSpec[] = [
  {
    type: 'core.if',
    label: 'If',
    group: 'flow',
    description: 'Sends each item to "true" or "false" depending on conditions.',
    inputs: 1,
    outputs: ['true', 'false'],
    params: [...conditionParams],
    run: (run) => ({ outputs: partition(run) }),
  },
  {
    type: 'core.filter',
    label: 'Filter',
    group: 'flow',
    description: 'Keeps only the items that match the conditions.',
    inputs: 1,
    outputs: ['kept'],
    params: [...conditionParams],
    run: (run) => ({ outputs: [partition(run)[0]] }),
  },
  {
    type: 'core.switch',
    label: 'Switch',
    group: 'flow',
    description: 'Sends each item to the output of the first rule it matches.',
    inputs: 1,
    outputs: null,
    params: [
      { key: 'rules', label: 'Rules', kind: 'rules', default: [] },
      { key: 'fallback', label: 'Fallback output for unmatched items', kind: 'boolean', default: false },
    ],
    run: (run) => ({ outputs: routeByRules(run) }),
  },
  {
    type: 'core.merge',
    label: 'Merge',
    group: 'flow',
    description: 'Waits for both inputs, then appends them, pairs them by position, or picks one.',
    inputs: 2,
    outputs: ['main'],
    params: [
      { key: 'mode', label: 'Mode', kind: 'select', default: 'append', options: ['append', 'combineByIndex', 'chooseBranch'] },
      { key: 'output', label: 'Branch to keep', kind: 'select', default: 'input1', options: ['input1', 'input2'] },
    ],
    run: (run) => ({ outputs: [merge(run)] }),
  },
  {
    type: 'core.noop',
    label: 'No Operation',
    group: 'flow',
    description: 'Passes items through unchanged.',
    inputs: 1,
    outputs: ['main'],
    params: [],
    run: passThrough,
  },
  {
    type: 'core.wait',
    label: 'Wait',
    group: 'flow',
    description: 'Pauses the execution, then continues with the same items.',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'seconds', label: 'Seconds', kind: 'number', default: 5 }],
    run: (run) => {
      const ms = paramNumber(run, 'seconds', 0) * 1000;
      return { effect: { type: 'wait', ms: ms >= 0 ? ms : 0 } };
    },
    resume: resumePassThrough,
  },
  {
    type: 'core.respond',
    label: 'Respond to Webhook',
    group: 'flow',
    description: 'Sends the HTTP response for the webhook that started the run.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'status', label: 'Status code', kind: 'number', default: 200 },
      { key: 'contentType', label: 'Content type', kind: 'text', default: 'application/json' },
      { key: 'body', label: 'Body', kind: 'json', default: '', hint: 'empty sends the incoming items' },
    ],
    run: (run) => ({ effect: respondEffect(run) }),
    resume: resumePassThrough,
  },
];
