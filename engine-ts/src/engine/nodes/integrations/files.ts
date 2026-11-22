/**
 * RSS Read and Files: the host fetches feeds and reads or writes files in
 * FlowDroid's own folder (also visible in Ubuntu as /root/files).
 */

import { fail } from '../../../errors.ts';
import { getKey, isObj, type Obj } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { checkEffectError, itemsOf, paramText, withField, type NodeRun, type NodeSpec } from '../spec.ts';
import { filePath } from '../file_refs.ts';
import { asItems } from './api.ts';

const FILE_OPERATIONS = ['read', 'write', 'append', 'list', 'delete'];

/** One result per item from the host, each turned into items. */
function perItemResults(key: string, what: string) {
  return (run: NodeRun, result: Obj): Item[][] => {
    checkEffectError(result);
    const list = getKey(result, key);
    const expected = itemsOf(run).length;
    if (!Array.isArray(list) || list.length !== expected) fail('NodeError', `expected ${expected} ${what}`);
    return [list.flatMap((entry) => (Array.isArray(entry) ? entry.filter(isObj) : asItems(entry)))];
  };
}

/** Extract Text: one result per item, `{ text }` or `{ error }`, stored under the chosen field. */
function extractItems(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const list = getKey(result, 'results');
  const items = itemsOf(run);
  if (!Array.isArray(list) || list.length !== items.length) fail('NodeError', `expected ${items.length} results`);
  const field = paramText(run, 'field', 0) === '' ? 'text' : paramText(run, 'field', 0);
  return [items.map((item, i) => {
    const entry = list[i];
    const error = isObj(entry) ? getKey(entry, 'error') : 'no result';
    if (typeof error === 'string') fail('NodeError', error);
    const text = isObj(entry) ? getKey(entry, 'text') : '';
    return withField([item], field, typeof text === 'string' ? text : '')[0]!;
  })];
}

export const fileNodes: NodeSpec[] = [
  {
    type: 'files.extract',
    label: 'Extract Text',
    group: 'data',
    description: 'Gets the text out of a file: PDF, Word (.docx), HTML, Markdown, CSV, JSON or plain text.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'path', label: 'File', kind: 'text', default: '{{ $json.file.path }}' },
      { key: 'field', label: 'Put the text in', kind: 'text', default: 'text' },
    ],
    run: (run) => ({
      effect: {
        type: 'extract',
        files: itemsOf(run).map((_, i) => {
          const path = filePath(run, 'path', i);
          if (path === '') fail('NodeError', 'file is required');
          return path;
        }),
      },
    }),
    resume: extractItems,
  },
  {
    type: 'rss.read',
    label: 'RSS Read',
    group: 'network',
    description: 'Reads an RSS or Atom feed and outputs one item per post.',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'url', label: 'Feed URL', kind: 'text', default: '' }],
    run: (run) => ({
      effect: {
        type: 'rss',
        urls: itemsOf(run).map((_, i) => {
          const url = paramText(run, 'url', i);
          if (url === '') fail('NodeError', 'feed URL is required');
          return url;
        }),
      },
    }),
    resume: perItemResults('feeds', 'feeds'),
  },
  {
    type: 'files',
    label: 'Files',
    group: 'system',
    description: 'Reads, writes, lists or deletes text files in FlowDroid’s folder (in Ubuntu: /root/files).',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'read', options: FILE_OPERATIONS },
      { key: 'path', label: 'Path', kind: 'text', default: 'notes.txt', hint: 'inside FlowDroid’s folder; empty = the folder (list)' },
      { key: 'content', label: 'Content (write, append)', kind: 'text', default: '{{ $json.text }}' },
    ],
    run: (run) => {
      const operation = paramText(run, 'operation', 0);
      if (!FILE_OPERATIONS.includes(operation)) fail('NodeError', `unknown operation ${operation}`);
      const writes = operation === 'write' || operation === 'append';
      const requests = itemsOf(run).map((_, i) => {
        const path = paramText(run, 'path', i);
        if (path === '' && operation !== 'list') fail('NodeError', 'path is required');
        return { operation, path, content: writes ? paramText(run, 'content', i) : null };
      });
      return { effect: { type: 'file', requests } };
    },
    resume: perItemResults('results', 'file results'),
  },
];
