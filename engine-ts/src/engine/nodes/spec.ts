/** The contract every node type implements, plus helpers shared by node implementations. */

import { fail } from '../../errors.ts';
import { render } from '../../expression/template.ts';
import { clone, cloneObj, getKey, isObj, setKey, toNum, toTemplateStr, type Obj, type Val } from '../../value.ts';
import { itemContext, type Item } from '../context.ts';
import type { WorkflowNode } from '../workflow.ts';

export type ParamKind =
  | 'text' | 'number' | 'boolean' | 'select' | 'json'
  | 'conditions' | 'rules' | 'fields' | 'keyValues' | 'credential'
  | 'workflow' | 'code' | 'tools';

export interface ParamSpec {
  key: string;
  label: string;
  kind: ParamKind;
  default: Val;
  options?: string[];
  hint?: string;
}

export type NodeGroup =
  | 'trigger' | 'flow' | 'data' | 'network' | 'android'
  | 'ai' | 'communication' | 'database' | 'productivity' | 'system';

export interface NodeRun {
  node: WorkflowNode;
  /** The node's parameters with spec defaults filled in. */
  params: Obj;
  /** Items per input; most nodes read only `inputs[0]`. */
  inputs: Item[][];
  /** Expression variables shared by every item. */
  base: Obj;
  /**
   * In `run`: what this node kept from its previous run in this execution
   * (`memory`), or null. In `step`: the `memo` it returned with its last effect.
   */
  memo: Val;
}

/**
 * A node either produces outputs now, or asks the host to perform an effect first.
 * `memory` (outputs) is kept for the node's next run; `memo` (effect) comes back in `step`.
 */
export type NodeResult = { outputs: Item[][]; memory?: Val } | { effect: Obj; memo?: Val };

/** After an effect: outputs, or another effect for a node that needs several round trips. */
export type StepResult = { outputs: Item[][] } | { effect: Obj; memo: Val };

export interface NodeSpec {
  type: string;
  label: string;
  group: NodeGroup;
  description: string;
  inputs: number;
  /** Output labels; `null` when they come from the `rules` parameter (Switch). */
  outputs: string[] | null;
  params: ParamSpec[];
  run(run: NodeRun): NodeResult;
  /** Turns the host's effect result into outputs; only for effect nodes. */
  resume?(run: NodeRun, result: Obj): Item[][];
  /** Like `resume`, but may ask for another effect; used instead of it when present. */
  step?(run: NodeRun, result: Obj): StepResult;
}

export function itemsOf(run: NodeRun): Item[] {
  return run.inputs[0] ?? [];
}

export function ctxFor(run: NodeRun, index: number): Obj {
  return itemContext(run.base, itemsOf(run)[index] ?? {}, index);
}

/** A parameter rendered for one item. */
export function paramValue(run: NodeRun, key: string, index: number): Val {
  return render(getKey(run.params, key), ctxFor(run, index));
}

export function paramText(run: NodeRun, key: string, index: number): string {
  return toTemplateStr(paramValue(run, key, index));
}

export function paramNumber(run: NodeRun, key: string, index: number): number {
  return toNum(paramValue(run, key, index));
}

/** Rows of a list parameter (`fields`, `keyValues`, `conditions`); each must be an object. */
export function rows(run: NodeRun, key: string): Obj[] {
  const list = getKey(run.params, key);
  if (!Array.isArray(list)) return [];
  return list.map((row, i) => {
    if (!isObj(row)) fail('NodeError', `${key} row ${i} must be an object`);
    return row;
  });
}

export function passThrough(run: NodeRun): NodeResult {
  return { outputs: [itemsOf(run)] };
}

/** Fails with the host's error, if the effect result carries one. */
export function checkEffectError(result: Obj): void {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
}

/** Resume for effects that produce nothing: fail on error, else pass the items on. */
export function resumePassThrough(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  return [itemsOf(run)];
}

/** Copies of `items`, each with `field` set to `value`. */
export function withField(items: Item[], field: string, value: Val): Item[] {
  return items.map((item) => {
    const copy = cloneObj(item);
    setKey(copy, field, clone(value));
    return copy;
  });
}
