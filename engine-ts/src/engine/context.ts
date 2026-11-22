/** Builds the variables an expression can see while a node runs. */

import { setKey, type Obj } from '../value.ts';
import type { Workflow } from './workflow.ts';

export type Item = Obj;

/** Variables shared by every item of one node run. */
export function baseContext(wf: Workflow, last: Record<string, Item[]>, items: Item[], nowIso: string): Obj {
  const nodes: Obj = {};
  for (const name of Object.keys(last)) {
    const output = last[name] ?? [];
    setKey(nodes, name, { json: output[0] ?? null, all: output });
  }
  return {
    $workflow: { id: wf.id, name: wf.name },
    $vars: wf.variables,
    $now: nowIso,
    $node: nodes,
    $items: items,
  };
}

/** Adds the current item (`$json`) and its position (`$index`). */
export function itemContext(base: Obj, item: Item, index: number): Obj {
  return { ...base, $json: item, $index: index };
}
