/** Nodes that reshape items: no side effects, outputs computed immediately. */

import { fail } from '../../errors.ts';
import { render } from '../../expression/template.ts';
import {
  clone, cloneObj, compareStrings, getKey, getPath, isObj, lastSegment, setPath, stringify, toInt, toStr,
  type Obj, type Val,
} from '../../value.ts';
import type { Item } from '../context.ts';
import { ctxFor, itemsOf, paramText, rows, type NodeRun, type NodeSpec } from './spec.ts';

function setFields(run: NodeRun): Item[] {
  const fields = rows(run, 'fields');
  const keepOnlySet = getKey(run.params, 'keepOnlySet') === true;
  return itemsOf(run).map((item, i) => {
    const ctx = ctxFor(run, i);
    const out: Obj = keepOnlySet ? {} : cloneObj(item);
    for (const field of fields) {
      const name = toStr(render(getKey(field, 'name'), ctx));
      if (name === '') fail('NodeError', 'field name is required');
      setPath(out, name, clone(render(getKey(field, 'value'), ctx)));
    }
    return out;
  });
}

function requiredField(run: NodeRun): string {
  const field = paramText(run, 'field', 0);
  if (field === '') fail('NodeError', 'field is required');
  return field;
}

function splitOut(run: NodeRun): Item[] {
  const field = requiredField(run);
  const key = lastSegment(field);
  return itemsOf(run).flatMap((item) => {
    const list = getPath(item, field);
    if (!Array.isArray(list)) fail('NodeError', `field '${field}' is not a list`);
    return list.map((entry): Item => (isObj(entry) ? cloneObj(entry) : { [key]: clone(entry) }));
  });
}

function aggregate(run: NodeRun): Item[] {
  const items = itemsOf(run);
  const field = paramText(run, 'field', 0);
  const out: Obj = {};
  if (field === '') out['items'] = items.map(clone);
  else setPath(out, lastSegment(field), items.map((item) => clone(getPath(item, field))));
  return [out];
}

function limit(run: NodeRun): Item[] {
  const max = Math.max(toInt(render(getKey(run.params, 'max'), ctxFor(run, 0))), 0);
  return itemsOf(run).slice(0, max);
}

/** Total order: numbers (not NaN) first, then strings, then everything else by its text. */
function compareValues(a: Val, b: Val): number {
  const rank = (v: Val): number => (typeof v === 'number' && !Number.isNaN(v) ? 0 : typeof v === 'string' ? 1 : 2);
  const ra = rank(a);
  const rb = rank(b);
  if (ra !== rb) return ra - rb;
  if (typeof a === 'number' && typeof b === 'number') return a < b ? -1 : a > b ? 1 : 0;
  return compareStrings(toStr(a), toStr(b));
}

function sort(run: NodeRun): Item[] {
  const field = requiredField(run);
  const direction = getKey(run.params, 'order') === 'desc' ? -1 : 1;
  return [...itemsOf(run)].sort((a, b) => direction * compareValues(getPath(a, field), getPath(b, field)));
}

function removeDuplicates(run: NodeRun): Item[] {
  const field = paramText(run, 'field', 0);
  const seen = new Set<string>();
  return itemsOf(run).filter((item) => {
    const key = stringify(field === '' ? item : getPath(item, field));
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

const fieldParam = (label: string, hint: string) =>
  ({ key: 'field', label, kind: 'text', default: '', hint }) as const;

export const dataNodes: NodeSpec[] = [
  {
    type: 'core.set',
    label: 'Edit Fields (Set)',
    group: 'data',
    description: 'Adds or changes fields on every item. Names may be dotted paths.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'fields', label: 'Fields', kind: 'fields', default: [] },
      { key: 'keepOnlySet', label: 'Keep only these fields', kind: 'boolean', default: false },
    ],
    run: (run) => ({ outputs: [setFields(run)] }),
  },
  {
    type: 'core.splitOut',
    label: 'Split Out',
    group: 'data',
    description: 'Turns a list field into one item per entry.',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('List field', 'e.g. data.users')],
    run: (run) => ({ outputs: [splitOut(run)] }),
  },
  {
    type: 'core.aggregate',
    label: 'Aggregate',
    group: 'data',
    description: 'Collects all items (or one field of each) into a single item.',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('Field to collect', 'empty collects whole items')],
    run: (run) => ({ outputs: [aggregate(run)] }),
  },
  {
    type: 'core.sort',
    label: 'Sort',
    group: 'data',
    description: 'Sorts items by a field.',
    inputs: 1,
    outputs: ['main'],
    params: [
      fieldParam('Sort by field', 'e.g. price'),
      { key: 'order', label: 'Order', kind: 'select', default: 'asc', options: ['asc', 'desc'] },
    ],
    run: (run) => ({ outputs: [sort(run)] }),
  },
  {
    type: 'core.removeDuplicates',
    label: 'Remove Duplicates',
    group: 'data',
    description: 'Keeps the first item for each distinct value of a field (or of the whole item).',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('Compare field', 'empty compares whole items')],
    run: (run) => ({ outputs: [removeDuplicates(run)] }),
  },
  {
    type: 'core.limit',
    label: 'Limit',
    group: 'data',
    description: 'Keeps only the first N items.',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'max', label: 'Max items', kind: 'number', default: 1 }],
    run: (run) => ({ outputs: [limit(run)] }),
  },
];
