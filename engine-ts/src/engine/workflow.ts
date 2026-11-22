/** Workflow documents: parsing untrusted JSON into a checked model. */

import { fail } from '../errors.ts';
import { parseJson } from '../json.ts';
import { getKey, isObj, type Obj, type Val } from '../value.ts';

export interface WorkflowNode {
  id: string;
  name: string;
  type: string;
  params: Obj;
  disabled: boolean;
  continueOnFail: boolean;
  /** Output saved in the editor, used instead of running the node when `usePinnedData` is set. */
  pinned: Obj[] | null;
  /** After a failed effect, run the node again up to `maxTries` times in all. */
  retryOnFail: boolean;
  maxTries: number;
  /** Milliseconds between tries. */
  waitBetweenTries: number;
}

export interface Connection {
  from: string;
  output: number;
  to: string;
  input: number;
}

export interface Workflow {
  id: string;
  name: string;
  nodes: WorkflowNode[];
  connections: Connection[];
  variables: Obj;
  /** Manual test runs set this so nodes with pinned output reuse it. */
  usePinned: boolean;
}

export function parseWorkflow(json: string): Workflow {
  const doc = parseJson(json, 'workflow');
  if (!isObj(doc)) fail('InputError', 'workflow must be an object');
  const nodes = getKey(doc, 'nodes');
  if (!Array.isArray(nodes)) fail('InputError', 'workflow.nodes must be an array');
  const connections = getKey(doc, 'connections') ?? [];
  if (!Array.isArray(connections)) fail('InputError', 'workflow.connections must be an array');
  return {
    id: text(getKey(doc, 'id'), ''),
    name: text(getKey(doc, 'name'), ''),
    nodes: nodes.map(parseNode),
    connections: connections.map(parseConnection),
    variables: objectOr(getKey(doc, 'variables')),
    usePinned: getKey(doc, 'usePinnedData') === true,
  };
}

function parseNode(v: Val, index: number): WorkflowNode {
  if (!isObj(v)) fail('InputError', `node ${index} must be an object`);
  const id = text(getKey(v, 'id'), '');
  if (id === '') fail('InputError', `node ${index} has no id`);
  const type = text(getKey(v, 'type'), '');
  if (type === '') fail('InputError', `node ${index} has no type`);
  return {
    id,
    name: text(getKey(v, 'name'), id),
    type,
    params: objectOr(getKey(v, 'params')),
    disabled: getKey(v, 'disabled') === true,
    continueOnFail: getKey(v, 'continueOnFail') === true,
    pinned: pinnedItems(getKey(v, 'pinned')),
    retryOnFail: getKey(v, 'retryOnFail') === true,
    maxTries: clampInt(getKey(v, 'maxTries'), 3, 1, MAX_TRIES),
    waitBetweenTries: clampInt(getKey(v, 'waitBetweenTries'), 1000, 0, MAX_WAIT_BETWEEN_TRIES),
  };
}

/** Most tries a node may ask for. */
export const MAX_TRIES = 10;
/** Longest wait between tries: five minutes. */
export const MAX_WAIT_BETWEEN_TRIES = 300_000;

function pinnedItems(v: Val): Obj[] | null {
  return Array.isArray(v) && v.every(isObj) ? (v as Obj[]) : null;
}

/** A whole number within `[min, max]`; `fallback` when `v` is not a finite number. */
function clampInt(v: Val, fallback: number, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(v))) + 0;
}

function parseConnection(v: Val, index: number): Connection {
  if (!isObj(v)) fail('InputError', `connection ${index} must be an object`);
  return {
    from: text(getKey(v, 'from'), ''),
    output: port(getKey(v, 'output')),
    to: text(getKey(v, 'to'), ''),
    input: port(getKey(v, 'input')),
  };
}

function text(v: Val, fallback: string): string {
  return typeof v === 'string' ? v : fallback;
}

function objectOr(v: Val): Obj {
  return isObj(v) ? v : {};
}

/** Highest number of inputs or outputs a node can have. */
export const MAX_PORTS = 64;

/** A valid port index: an integer in `[0, MAX_PORTS)`. */
export function isPort(v: Val): v is number {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 && v < MAX_PORTS;
}

/** A port index, defaulting to 0 when missing or invalid. */
function port(v: Val): number {
  return isPort(v) ? v + 0 : 0;
}

export function nodeById(wf: Workflow, id: string): WorkflowNode | undefined {
  return wf.nodes.find((n) => n.id === id);
}

export function outgoing(wf: Workflow, nodeId: string): Connection[] {
  return wf.connections.filter((c) => c.from === nodeId && nodeById(wf, c.to) !== undefined);
}

/** Input indexes of `nodeId` that some existing node feeds. */
export function connectedInputs(wf: Workflow, nodeId: string): number[] {
  const inputs = wf.connections
    .filter((c) => c.to === nodeId && nodeById(wf, c.from) !== undefined)
    .map((c) => c.input);
  return [...new Set(inputs)].sort((a, b) => a - b);
}
