/**
 * Runs a workflow as a deterministic state machine.
 *
 * Nodes run breadth-first from the trigger. A node with several inputs
 * (Merge) waits until every connected input has delivered, or until nothing
 * else is left to run. When a node needs a side effect, the run pauses with
 * status `waiting`; the host performs `pending.effect` and resumes.
 */

import { fail, messageOf } from '../errors.ts';
import { isoString } from '../time.ts';
import { getKey, isObj, setKey, type Obj, type Val } from '../value.ts';
import { baseContext, type Item } from './context.ts';
import { paramsWithDefaults, specFor } from './nodes/registry.ts';
import type { NodeRun, NodeSpec } from './nodes/spec.ts';
import { newState, type ExecutionState, type Task } from './state.ts';
import { connectedInputs, nodeById, outgoing, type Workflow, type WorkflowNode } from './workflow.ts';

/** Guards against workflows that loop forever. */
export const MAX_STEPS = 5000;

interface Ready {
  node: WorkflowNode;
  inputs: Item[][];
}

export function start(wf: Workflow, triggerId: string, items: Item[], now: number): ExecutionState {
  const trigger = nodeById(wf, triggerId);
  if (trigger === undefined) fail('InputError', `unknown trigger node ${triggerId}`);
  const state = newState(now);
  state.steps = 1;
  const pinned = wf.usePinned ? trigger.pinned : null;
  complete(wf, state, trigger, [pinned ?? items], null, now);
  drain(wf, state, now);
  return state;
}

export function resume(wf: Workflow, state: ExecutionState, result: Obj, now: number): ExecutionState {
  const pending = state.pending;
  const node = pending === null ? undefined : nodeById(wf, pending.node);
  if (pending === null || node === undefined) return fail('InputError', 'execution is not waiting for an effect result');
  const spec = specFor(node.type);
  if (spec === undefined || (spec.step === undefined && spec.resume === undefined)) {
    return fail('InputError', `node ${node.name} does not take effect results`);
  }
  state.pending = null;
  state.status = 'running';
  if (pending.retry) {
    // The wait before another try is over: run the node again from the start.
    execute(wf, state, { node, inputs: pending.inputs }, now, pending.attempt);
  } else {
    try {
      const run = makeRun(wf, state, node, spec, pending.inputs, now, pending.memo);
      const stepped = spec.step === undefined ? { outputs: spec.resume!(run, result) } : spec.step(run, result);
      if ('effect' in stepped) {
        state.pending = { ...pending, effect: stepped.effect, memo: stepped.memo };
        state.status = 'waiting';
      } else {
        complete(wf, state, node, stepped.outputs, null, now);
      }
    } catch (e) {
      const message = messageOf(e);
      if (node.retryOnFail && pending.attempt < node.maxTries) {
        state.pending = {
          node: node.id,
          inputs: pending.inputs,
          effect: { type: 'wait', ms: node.waitBetweenTries, reason: `retry ${pending.attempt + 1} of ${node.maxTries}: ${message}` },
          memo: null,
          attempt: pending.attempt + 1,
          retry: true,
        };
        state.status = 'waiting';
      } else {
        failNode(wf, state, node, message, now);
      }
    }
  }
  drain(wf, state, now);
  return state;
}

function drain(wf: Workflow, state: ExecutionState, now: number): void {
  while (state.status === 'running') {
    const ready = nextReady(wf, state);
    if (ready === null) {
      state.status = 'success';
      state.finishedAt = now;
    } else if (state.steps >= MAX_STEPS) {
      state.status = 'error';
      state.error = `execution stopped after ${MAX_STEPS} node runs`;
      state.finishedAt = now;
    } else {
      execute(wf, state, ready, now);
    }
  }
}

function nextReady(wf: Workflow, state: ExecutionState): Ready | null {
  for (let task = state.queue.shift(); task !== undefined; task = state.queue.shift()) {
    const node = nodeById(wf, task.node);
    if (node === undefined) continue;
    const spec = specFor(node.type);
    if (spec === undefined || spec.inputs < 2) return { node, inputs: [task.items] };
    const inputs = collect(wf, state, node, spec, task);
    if (inputs !== null) return { node, inputs };
  }
  return flushWaiting(wf, state);
}

/** Adds a task to its node's input slots; returns all inputs once every connected one has arrived. */
function collect(wf: Workflow, state: ExecutionState, node: WorkflowNode, spec: NodeSpec, task: Task): Item[][] | null {
  const stored = getKey(state.waiting, node.id);
  const slots: Val[] = Array.isArray(stored) ? stored : [];
  while (slots.length <= task.input) slots.push(null);
  const previous = slots[task.input];
  slots[task.input] = [...(Array.isArray(previous) ? previous : []), ...task.items];
  if (connectedInputs(wf, node.id).every((i) => slots[i] !== null && slots[i] !== undefined)) {
    delete state.waiting[node.id];
    return toInputs(slots, spec.inputs);
  }
  setKey(state.waiting, node.id, slots);
  return null;
}

/** With nothing else to run, the first waiting node runs with what it has. */
function flushWaiting(wf: Workflow, state: ExecutionState): Ready | null {
  for (const node of wf.nodes) {
    if (!Object.hasOwn(state.waiting, node.id)) continue;
    const stored = getKey(state.waiting, node.id);
    delete state.waiting[node.id];
    return { node, inputs: toInputs(Array.isArray(stored) ? stored : [], specFor(node.type)?.inputs ?? 1) };
  }
  return null;
}

function toInputs(slots: Val[], count: number): Item[][] {
  return Array.from({ length: Math.max(count, slots.length) }, (_, i) => {
    const slot = slots[i];
    return Array.isArray(slot) ? slot.filter(isObj) : [];
  });
}

function execute(wf: Workflow, state: ExecutionState, { node, inputs }: Ready, now: number, attempt = 1): void {
  state.steps++;
  if (node.disabled) {
    complete(wf, state, node, [inputs.flat()], null, now);
    return;
  }
  if (wf.usePinned && node.pinned !== null) {
    complete(wf, state, node, [node.pinned], null, now);
    return;
  }
  try {
    const spec = specFor(node.type);
    if (spec === undefined) fail('NodeError', `unknown node type ${node.type}`);
    const memory = Object.hasOwn(state.memory, node.id) ? getKey(state.memory, node.id) : null;
    const result = spec.run(makeRun(wf, state, node, spec, inputs, now, memory));
    if ('effect' in result) {
      state.pending = { node: node.id, inputs, effect: result.effect, memo: result.memo ?? null, attempt, retry: false };
      state.status = 'waiting';
    } else {
      if (result.memory !== undefined) remember(state, node.id, result.memory);
      complete(wf, state, node, result.outputs, null, now);
    }
  } catch (e) {
    failNode(wf, state, node, messageOf(e), now);
  }
}

/** Keeps [memory] for the node's next run; null forgets it. */
function remember(state: ExecutionState, nodeId: string, memory: Val): void {
  if (memory === null) delete state.memory[nodeId];
  else setKey(state.memory, nodeId, memory);
}

function makeRun(
  wf: Workflow,
  state: ExecutionState,
  node: WorkflowNode,
  spec: NodeSpec,
  inputs: Item[][],
  now: number,
  memo: Val = null,
): NodeRun {
  const last = state.last as Record<string, Item[]>;
  return {
    node,
    params: paramsWithDefaults(spec, node),
    inputs,
    base: baseContext(wf, last, inputs[0] ?? [], isoString(now)),
    memo,
  };
}

/** Records a node's outputs and queues every connected node that received items. */
function complete(wf: Workflow, state: ExecutionState, node: WorkflowNode, outputs: Item[][], error: string | null, now: number): void {
  state.runs.push({ node: node.id, name: node.name, at: now, error, output: outputs });
  setKey(state.last, node.name, outputs.flat());
  for (const c of outgoing(wf, node.id)) {
    const items = outputs[c.output] ?? [];
    if (items.length > 0) state.queue.push({ node: c.to, input: c.input, items });
  }
}

/** With "continue on fail", the error becomes an item; otherwise the execution stops. */
function failNode(wf: Workflow, state: ExecutionState, node: WorkflowNode, message: string, now: number): void {
  if (node.continueOnFail) {
    complete(wf, state, node, [[{ error: message }]], message, now);
    return;
  }
  state.runs.push({ node: node.id, name: node.name, at: now, error: message, output: [] });
  state.status = 'error';
  state.error = `${node.name}: ${message}`;
  state.finishedAt = now;
}
