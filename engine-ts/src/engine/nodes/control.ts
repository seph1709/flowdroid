/**
 * Loop Over Items and Execute Workflow: nodes that steer the run itself.
 */

import { fail } from '../../errors.ts';
import { getKey, isObj, type Obj, type Val } from '../../value.ts';
import type { Item } from '../context.ts';
import { checkEffectError, itemsOf, paramNumber, paramText, type NodeResult, type NodeRun, type NodeSpec } from './spec.ts';

function itemList(v: Val): Item[] {
  return Array.isArray(v) ? v.filter(isObj) : [];
}

/**
 * Hands items to the `loop` output a batch at a time. Whatever comes back
 * into the node is collected; when no batch is left, everything collected
 * goes out of `done`.
 */
function loop(run: NodeRun): NodeResult {
  const size = Math.trunc(paramNumber(run, 'batchSize', 0));
  const batch = size >= 1 ? size : 1;
  const memo = run.memo;
  let rest: Item[];
  let done: Item[];
  if (isObj(memo)) {
    rest = itemList(getKey(memo, 'rest'));
    done = [...itemList(getKey(memo, 'done')), ...itemsOf(run)];
  } else {
    rest = itemsOf(run);
    done = [];
  }
  if (isObj(memo) && rest.length === 0) return { outputs: [done, []], memory: null };
  return { outputs: [[], rest.slice(0, batch)], memory: { rest: rest.slice(batch), done } };
}

const RUN_MODES = ['allItems', 'eachItem'];

function callWorkflow(run: NodeRun): NodeResult {
  const workflowId = paramText(run, 'workflowId', 0);
  if (workflowId === '') fail('NodeError', 'choose a workflow');
  const mode = paramText(run, 'mode', 0);
  if (!RUN_MODES.includes(mode)) fail('NodeError', `unknown mode ${mode}`);
  const items = itemsOf(run);
  const runs = mode === 'eachItem' ? items.map((item) => [item]) : [items];
  return { effect: { type: 'workflow', workflowId, wait: getKey(run.params, 'wait') !== false, runs } };
}

/** The called workflow's output items, one list per call, in order. */
function workflowResults(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  if (getKey(run.params, 'wait') === false) return [itemsOf(run)];
  const expected = paramText(run, 'mode', 0) === 'eachItem' ? itemsOf(run).length : 1;
  const outputs = getKey(result, 'outputs');
  if (!Array.isArray(outputs) || outputs.length !== expected || !outputs.every(Array.isArray)) {
    fail('NodeError', `expected ${expected} workflow results`);
  }
  return [outputs.flatMap(itemList)];
}

export const controlNodes: NodeSpec[] = [
  {
    type: 'core.loop',
    label: 'Loop Over Items',
    group: 'flow',
    description: 'Sends items through the “loop” branch a batch at a time; connect its end back here. Then outputs everything on “done”.',
    inputs: 1,
    outputs: ['done', 'loop'],
    params: [{ key: 'batchSize', label: 'Batch size', kind: 'number', default: 1 }],
    run: loop,
  },
  {
    type: 'core.executeWorkflow',
    label: 'Execute Workflow',
    group: 'flow',
    description: 'Runs another workflow (it starts at its “When Called by a Workflow” trigger) and outputs what it returned.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'workflowId', label: 'Workflow', kind: 'workflow', default: '' },
      { key: 'mode', label: 'Run it', kind: 'select', default: 'allItems', options: RUN_MODES },
      { key: 'wait', label: 'Wait for it to finish', kind: 'boolean', default: true },
    ],
    run: callWorkflow,
    resume: workflowResults,
  },
];
