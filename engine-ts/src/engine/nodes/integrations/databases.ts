/** Supabase, Airtable, Notion and the on-phone table store. */

import { fail } from '../../../errors.ts';
import { render } from '../../../expression/template.ts';
import { parseJson } from '../../../json.ts';
import { getKey, isObj, setKey, toInt, toTemplateStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { ctxFor, itemsOf, paramText, paramValue, resumePassThrough, rows, type NodeRun, type NodeSpec, type ParamSpec } from '../spec.ts';
import { apiRequest, apiResume, asItems, credentialParam, enc, perItem } from './api.ts';

function required(run: NodeRun, key: string, index: number, label: string): string {
  const v = paramText(run, key, index);
  if (v === '') fail('NodeError', `${label} is required`);
  return v;
}

/** Equality filters from a key/value list, rendered for one item. */
function filters(run: NodeRun, index: number): [string, string][] {
  const ctx = ctxFor(run, index);
  return rows(run, 'filters')
    .map((row): [string, string] => [toTemplateStr(render(getKey(row, 'name'), ctx)), toTemplateStr(render(getKey(row, 'value'), ctx))])
    .filter(([name]) => name !== '');
}

/** A JSON parameter: objects and lists as they are; text is parsed as JSON when it is valid JSON. */
function jsonParam(run: NodeRun, key: string, index: number): Val {
  const v = paramValue(run, key, index);
  if (typeof v !== 'string') return v;
  try {
    return parseJson(v, key);
  } catch {
    return v;
  }
}

// ---------- Supabase (PostgREST) ----------

function supabase(run: NodeRun, index: number): Obj {
  const table = required(run, 'table', index, 'table');
  const operation = paramText(run, 'operation', index);
  const where = filters(run, index).map(([name, value]) => `${enc(name)}=eq.${enc(value)}`);
  const base = `{cred:url}/rest/v1/${enc(table)}`;
  const headers: Obj = { apikey: '{cred:serviceKey}', Authorization: 'Bearer {cred:serviceKey}' };
  const query = (parts: string[]): string => (parts.length === 0 ? '' : `?${parts.join('&')}`);
  if ((operation === 'update' || operation === 'delete') && where.length === 0) {
    fail('NodeError', `add at least one filter before ${operation === 'update' ? 'updating' : 'deleting'} rows`);
  }
  switch (operation) {
    case 'select': {
      const limit = Math.max(toInt(paramValue(run, 'limit', index)), 1);
      return apiRequest(run, { method: 'GET', url: base + query(['select=*', ...where, `limit=${limit}`]), headers });
    }
    case 'insert':
      setKey(headers, 'Prefer', 'return=representation');
      return apiRequest(run, { method: 'POST', url: base, headers, body: jsonParam(run, 'row', index) });
    case 'update':
      setKey(headers, 'Prefer', 'return=representation');
      return apiRequest(run, { method: 'PATCH', url: base + query(where), headers, body: jsonParam(run, 'row', index) });
    case 'delete':
      setKey(headers, 'Prefer', 'return=representation');
      return apiRequest(run, { method: 'DELETE', url: base + query(where), headers });
    default:
      return fail('NodeError', `unknown operation ${operation}`);
  }
}

// ---------- Airtable ----------

function airtable(run: NodeRun, index: number): Obj {
  const base = `https://api.airtable.com/v0/${enc(required(run, 'baseId', index, 'base ID'))}/${enc(required(run, 'table', index, 'table'))}`;
  const headers: Obj = { Authorization: 'Bearer {cred:token}' };
  const operation = paramText(run, 'operation', index);
  switch (operation) {
    case 'list': {
      const parts = [`maxRecords=${Math.max(toInt(paramValue(run, 'limit', index)), 1)}`];
      const formula = paramText(run, 'filterFormula', index);
      if (formula !== '') parts.push(`filterByFormula=${enc(formula)}`);
      return apiRequest(run, { method: 'GET', url: `${base}?${parts.join('&')}`, headers });
    }
    case 'create':
      return apiRequest(run, { method: 'POST', url: base, headers, body: { fields: jsonParam(run, 'fields', index) } });
    case 'update': {
      const id = required(run, 'recordId', index, 'record ID');
      return apiRequest(run, { method: 'PATCH', url: `${base}/${enc(id)}`, headers, body: { fields: jsonParam(run, 'fields', index) } });
    }
    default:
      return fail('NodeError', `unknown operation ${operation}`);
  }
}

/** Airtable records as items: the record id and time next to its fields. */
function airtableItems(body: Val): Item[] {
  const records = isObj(body) && Array.isArray(getKey(body, 'records')) ? (getKey(body, 'records') as Val[]) : [body];
  return records.map((record): Item => {
    const r = isObj(record) ? record : {};
    const item: Item = { id: getKey(r, 'id'), createdTime: getKey(r, 'createdTime') };
    const fields = getKey(r, 'fields');
    if (isObj(fields)) for (const key of Object.keys(fields)) setKey(item, key, getKey(fields, key));
    return item;
  });
}

// ---------- Notion ----------

function notion(run: NodeRun, index: number): Obj {
  const database = required(run, 'databaseId', index, 'database ID');
  const headers: Obj = { Authorization: 'Bearer {cred:token}', 'Notion-Version': '2022-06-28' };
  const operation = paramText(run, 'operation', index);
  switch (operation) {
    case 'query': {
      const filter = jsonParam(run, 'filter', index);
      const body: Obj = { page_size: Math.min(Math.max(toInt(paramValue(run, 'limit', index)), 1), 100) };
      if (isObj(filter)) body['filter'] = filter;
      return apiRequest(run, { method: 'POST', url: `https://api.notion.com/v1/databases/${enc(database)}/query`, headers, body });
    }
    case 'create':
      return apiRequest(run, {
        method: 'POST',
        url: 'https://api.notion.com/v1/pages',
        headers,
        body: { parent: { database_id: database }, properties: jsonParam(run, 'properties', index) },
      });
    default:
      return fail('NodeError', `unknown operation ${operation}`);
  }
}

function notionItems(body: Val): Item[] {
  const pages = isObj(body) && Array.isArray(getKey(body, 'results')) ? (getKey(body, 'results') as Val[]) : [body];
  return pages.map((page): Item => {
    const p = isObj(page) ? page : {};
    return { id: getKey(p, 'id'), url: getKey(p, 'url'), properties: getKey(p, 'properties') };
  });
}

// ---------- Table store on the phone ----------

function tableEffect(run: NodeRun): { effect: Obj } {
  const operation = paramText(run, 'operation', 0);
  if (!['insert', 'find', 'update', 'delete'].includes(operation)) fail('NodeError', `unknown operation ${operation}`);
  const table = required(run, 'table', 0, 'table');
  const requests = itemsOf(run).map((_, i): Obj => {
    const where: Obj = {};
    for (const [name, value] of filters(run, i)) setKey(where, name, value);
    const row = operation === 'insert' || operation === 'update' ? jsonParam(run, 'row', i) : null;
    if (row !== null && !isObj(row)) fail('NodeError', 'row must be an object');
    return { where, row, limit: Math.max(toInt(paramValue(run, 'limit', i)), 1) };
  });
  return { effect: { type: 'table', table, operation, requests } };
}

function tableItems(run: NodeRun, result: Obj): Item[][] {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const rowsOut = getKey(result, 'rows');
  if (!Array.isArray(rowsOut)) return resumePassThrough(run, result);
  return [rowsOut.filter(isObj)];
}

const filtersParam: ParamSpec = { key: 'filters', label: 'Where (column equals value)', kind: 'keyValues', default: [] };

export const databaseNodes: NodeSpec[] = [
  {
    type: 'db.supabase',
    label: 'Supabase',
    group: 'database',
    description: 'Reads, inserts, updates or deletes rows in a Supabase table.',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['supabase']),
      { key: 'operation', label: 'Operation', kind: 'select', default: 'select', options: ['select', 'insert', 'update', 'delete'] },
      { key: 'table', label: 'Table', kind: 'text', default: '' },
      { ...filtersParam },
      { key: 'row', label: 'Row (insert or update)', kind: 'json', default: '{{ $json }}' },
      { key: 'limit', label: 'Max rows', kind: 'number', default: 100 },
    ],
    run: (run) => perItem(run, (i) => supabase(run, i)),
    resume: apiResume('Supabase', (body) => asItems(body)),
  },
  {
    type: 'db.airtable',
    label: 'Airtable',
    group: 'database',
    description: 'Lists, creates or updates records in an Airtable table.',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['airtable']),
      { key: 'operation', label: 'Operation', kind: 'select', default: 'list', options: ['list', 'create', 'update'] },
      { key: 'baseId', label: 'Base ID', kind: 'text', default: '', hint: 'starts with app' },
      { key: 'table', label: 'Table', kind: 'text', default: '' },
      { key: 'recordId', label: 'Record ID (update)', kind: 'text', default: '' },
      { key: 'fields', label: 'Fields (create or update)', kind: 'json', default: '{{ $json }}' },
      { key: 'filterFormula', label: 'Filter formula (list)', kind: 'text', default: '' },
      { key: 'limit', label: 'Max records', kind: 'number', default: 100 },
    ],
    run: (run) => perItem(run, (i) => airtable(run, i)),
    resume: apiResume('Airtable', airtableItems),
  },
  {
    type: 'db.notion',
    label: 'Notion',
    group: 'database',
    description: 'Queries a Notion database or adds a page to it.',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['notion']),
      { key: 'operation', label: 'Operation', kind: 'select', default: 'query', options: ['query', 'create'] },
      { key: 'databaseId', label: 'Database ID', kind: 'text', default: '' },
      { key: 'filter', label: 'Filter (query, Notion JSON)', kind: 'json', default: '' },
      { key: 'properties', label: 'Properties (create, Notion JSON)', kind: 'json', default: '' },
      { key: 'limit', label: 'Max pages', kind: 'number', default: 50 },
    ],
    run: (run) => perItem(run, (i) => notion(run, i)),
    resume: apiResume('Notion', notionItems),
  },
  {
    type: 'db.table',
    label: 'Phone Table',
    group: 'database',
    description: 'Stores rows on this phone: insert, find, update or delete, no account needed.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'insert', options: ['insert', 'find', 'update', 'delete'] },
      { key: 'table', label: 'Table name', kind: 'text', default: 'notes' },
      { ...filtersParam },
      { key: 'row', label: 'Row (insert or update)', kind: 'json', default: '{{ $json }}' },
      { key: 'limit', label: 'Max rows (find)', kind: 'number', default: 100 },
    ],
    run: tableEffect,
    resume: tableItems,
  },
];
