/**
 * Execution state. The host stores it between steps (for example while an
 * HTTP request is in flight) and passes it back to `resumeExecution`.
 */

import { fail } from '../errors.ts';
import { parseJson } from '../json.ts';
import { getKey, isObj, stringify, type Obj, type Val } from '../value.ts';
import type { Item } from './context.ts';
import { isPort, nodeById, type Workflow } from './workflow.ts';

export type Status = 'running' | 'waiting' | 'success' | 'error';

/** Items delivered to one input of a node, not yet run. */
export interface Task {
  node: string;
  input: number;
  items: Item[];
}

/** An effect node waiting for the host's result. */
export interface Pending {
  node: string;
  inputs: Item[][];
  effect: Obj;
  /** The node's own progress between round trips (AI Agent). */
  memo: Val;
  /** Which try this is, from 1. */
  attempt: number;
  /** True while waiting before the node runs again after a failure. */
  retry: boolean;
}

export interface ExecutionState {
  status: Status;
  error: string | null;
  startedAt: number;
  finishedAt: number | null;
  steps: number;
  pending: Pending | null;
  queue: Task[];
  /** Multi-input nodes collecting inputs, by node id: one slot per input. */
  waiting: Obj;
  /** What a node keeps between its runs in one execution (Loop Over Items), by node id. */
  memory: Obj;
  /** Latest output of each node, by node name, for `$node`. */
  last: Obj;
  /** One record per node run, in order. */
  runs: Val[];
}

export function newState(now: number): ExecutionState {
  return {
    status: 'running',
    error: null,
    startedAt: now,
    finishedAt: null,
    steps: 0,
    pending: null,
    queue: [],
    waiting: {},
    memory: {},
    last: {},
    runs: [],
  };
}

export function serializeState(s: ExecutionState): string {
  const p = s.pending;
  const pending = p === null
    ? null
    : { node: p.node, inputs: p.inputs, effect: p.effect, memo: p.memo, attempt: p.attempt, retry: p.retry };
  return stringify({
    status: s.status,
    error: s.error,
    startedAt: s.startedAt,
    finishedAt: s.finishedAt,
    steps: s.steps,
    pending,
    queue: s.queue.map((t) => ({ node: t.node, input: t.input, items: t.items })),
    waiting: s.waiting,
    memory: s.memory,
    last: s.last,
    runs: s.runs,
  });
}

/** Parses a state saved by `serializeState`; it must be waiting for an effect result. */
export function parseState(json: string, wf: Workflow): ExecutionState {
  const doc = parseJson(json, 'state');
  if (!isObj(doc)) fail('InputError', 'state must be an object');
  if (getKey(doc, 'status') !== 'waiting') fail('InputError', 'execution is not waiting for an effect result');
  const steps = getKey(doc, 'steps');
  const startedAt = getKey(doc, 'startedAt');
  const runs = getKey(doc, 'runs');
  if (typeof steps !== 'number' || !Number.isInteger(steps) || steps < 0) invalid('steps');
  if (typeof startedAt !== 'number') invalid('startedAt');
  if (!Array.isArray(runs)) invalid('runs');
  return {
    status: 'waiting',
    error: null,
    startedAt,
    finishedAt: null,
    steps,
    pending: parsePending(getKey(doc, 'pending'), wf),
    queue: parseQueue(getKey(doc, 'queue'), wf),
    waiting: objectOf(getKey(doc, 'waiting'), 'waiting', (slots) => Array.isArray(slots) && slots.every((s) => s === null || isItems(s))),
    memory: objectOf(getKey(doc, 'memory') ?? {}, 'memory', () => true),
    last: objectOf(getKey(doc, 'last'), 'last', isItems),
    runs,
  };
}

function invalid(field: string): never {
  return fail('InputError', `state.${field} is invalid`);
}

function isItems(v: Val): v is Item[] {
  return Array.isArray(v) && v.every(isObj);
}

function isNodeId(v: Val, wf: Workflow): v is string {
  return typeof v === 'string' && nodeById(wf, v) !== undefined;
}

function parsePending(v: Val, wf: Workflow): Pending {
  if (!isObj(v)) invalid('pending');
  const node = getKey(v, 'node');
  const inputs = getKey(v, 'inputs');
  const effect = getKey(v, 'effect');
  if (!isNodeId(node, wf) || !Array.isArray(inputs) || !inputs.every(isItems) || !isObj(effect)) invalid('pending');
  const attempt = getKey(v, 'attempt') ?? 1;
  if (typeof attempt !== 'number' || !Number.isInteger(attempt) || attempt < 1) invalid('pending');
  return {
    node,
    inputs: inputs as Item[][],
    effect,
    memo: getKey(v, 'memo') ?? null,
    attempt: attempt + 0,
    retry: getKey(v, 'retry') === true,
  };
}

function parseQueue(v: Val, wf: Workflow): Task[] {
  if (!Array.isArray(v)) invalid('queue');
  return v.map((t) => {
    if (!isObj(t)) invalid('queue');
    const node = getKey(t, 'node');
    const input = getKey(t, 'input');
    const items = getKey(t, 'items');
    if (!isNodeId(node, wf) || !isPort(input) || !isItems(items)) {
      invalid('queue');
    }
    return { node, input: input + 0, items };
  });
}

function objectOf(v: Val, field: string, check: (entry: Val) => boolean): Obj {
  if (!isObj(v) || !Object.values(v).every(check)) invalid(field);
  return v;
}
