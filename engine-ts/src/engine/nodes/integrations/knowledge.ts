/**
 * Knowledge base (RAG): documents are split into chunks and indexed on the
 * phone; searches return the best-matching chunks as context for AI steps.
 * The host does the chunking, embedding, storage and ranking:
 *   add:    { added: [{ source, chunks }] }          one per item
 *   search: { results: [{ matches, context }] }      one per item
 *   info:   { rows: [...] }
 */

import { fail } from '../../../errors.ts';
import { getKey, isObj, toNum, type Obj } from '../../../value.ts';
import type { Item } from '../../context.ts';
import {
  checkEffectError, itemsOf, paramText, paramValue, resumePassThrough, withField,
  type NodeRun, type NodeSpec, type ParamSpec,
} from '../spec.ts';

/** `local` ranks by words on the phone (no key); the others compare meaning with embeddings. */
export const EMBEDDERS = ['local', 'openai', 'gemini', 'openaiCompatible'];
const INFO_OPERATIONS = ['collections', 'sources', 'deleteSource', 'clear'];

const collectionParam: ParamSpec = {
  key: 'collection', label: 'Knowledge base', kind: 'text', default: 'my-notes', hint: 'a name; created when first used',
};
const credentialParam: ParamSpec = {
  key: 'credential', label: 'Credential', kind: 'credential', default: '',
  options: ['openai', 'gemini', 'openaiCompatible'], hint: 'not needed for Words',
};

/** Text that isn't a number counts as 0. */
const finiteOrZero = (x: number): number => (Number.isFinite(x) ? x : 0);

function collectionOf(run: NodeRun): string {
  const name = paramText(run, 'collection', 0).trim();
  if (name === '') fail('NodeError', 'knowledge base name is required');
  return name;
}

function addEffect(run: NodeRun): { effect: Obj } {
  const embedder = paramText(run, 'embedder', 0);
  if (!EMBEDDERS.includes(embedder)) fail('NodeError', `unknown search kind ${embedder}`);
  const effect: Obj = { type: 'knowledge', op: 'add', collection: collectionOf(run), embedder };
  if (embedder !== 'local') {
    const credential = paramText(run, 'credential', 0);
    if (credential === '') fail('NodeError', 'choose a credential for the embeddings');
    effect['credential'] = credential;
    const model = paramText(run, 'model', 0);
    if (model !== '') effect['model'] = model;
  }
  const size = Math.round(toNum(paramValue(run, 'chunkSize', 0)));
  const chunkSize = Math.min(8000, Math.max(100, size > 0 ? size : 800));
  const overlap = finiteOrZero(Math.round(toNum(paramValue(run, 'overlap', 0))));
  effect['chunkSize'] = chunkSize;
  effect['overlap'] = Math.min(Math.floor(chunkSize / 2), Math.max(0, overlap));
  effect['documents'] = itemsOf(run).map((item, i): Obj => {
    const text = paramText(run, 'text', i);
    // Saving nothing silently hides a wrong field (e.g. a shared file's text is in fileText).
    if (text.trim() === '') fail('NodeError', `nothing to add: Text is empty (item ${i + 1})`);
    return { text, source: paramText(run, 'source', i), metadata: item };
  });
  return { effect };
}

function searchEffect(run: NodeRun): { effect: Obj } {
  const effect: Obj = { type: 'knowledge', op: 'search', collection: collectionOf(run) };
  const credential = paramText(run, 'credential', 0);
  if (credential !== '') effect['credential'] = credential;
  effect['queries'] = itemsOf(run).map((_, i): Obj => {
    const k = Math.round(toNum(paramValue(run, 'topK', i)));
    return {
      query: paramText(run, 'query', i),
      topK: Math.min(50, Math.max(1, k > 0 ? k : 4)),
      minScore: Math.min(1, Math.max(0, finiteOrZero(toNum(paramValue(run, 'minScore', i))))),
    };
  });
  return { effect };
}

function infoEffect(run: NodeRun): { effect: Obj } {
  const op = paramText(run, 'operation', 0);
  if (!INFO_OPERATIONS.includes(op)) fail('NodeError', `unknown operation ${op}`);
  const effect: Obj = { type: 'knowledge', op };
  if (op !== 'collections') effect['collection'] = collectionOf(run);
  if (op === 'deleteSource') {
    const source = paramText(run, 'source', 0);
    if (source === '') fail('NodeError', 'source is required');
    effect['source'] = source;
  }
  return { effect };
}

/** Each item gets `knowledge` from the matching entry of the result list. */
function perItemResult(key: string) {
  return (run: NodeRun, result: Obj): Item[][] => {
    checkEffectError(result);
    const list = getKey(result, key);
    if (!Array.isArray(list)) return resumePassThrough(run, result);
    return [itemsOf(run).map((item, i) => {
      const entry = list[i];
      return withField([item], 'knowledge', isObj(entry) ? entry : {})[0]!;
    })];
  };
}

function infoRows(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const rowsOut = getKey(result, 'rows');
  if (!Array.isArray(rowsOut)) return resumePassThrough(run, result);
  return [rowsOut.filter(isObj)];
}

export const knowledgeNodes: NodeSpec[] = [
  {
    type: 'rag.add',
    label: 'Add to Knowledge Base',
    group: 'ai',
    description: 'Splits text into chunks and saves them on the phone for searching (RAG). Adding the same source again replaces it.',
    inputs: 1,
    outputs: ['main'],
    params: [
      collectionParam,
      { key: 'text', label: 'Text', kind: 'text', default: '{{ $json.text }}' },
      { key: 'source', label: 'Source', kind: 'text', default: '', hint: 'title, file or URL; shown with search results' },
      { key: 'embedder', label: 'Search by', kind: 'select', default: 'local', options: EMBEDDERS },
      credentialParam,
      { key: 'model', label: 'Embedding model', kind: 'text', default: '', hint: 'empty = the provider’s default' },
      { key: 'chunkSize', label: 'Chunk size (characters)', kind: 'number', default: 800 },
      { key: 'overlap', label: 'Overlap (characters)', kind: 'number', default: 100 },
    ],
    run: addEffect,
    resume: perItemResult('added'),
  },
  {
    type: 'rag.search',
    label: 'Search Knowledge Base',
    group: 'ai',
    description: 'Finds the chunks that best answer a question and outputs them as context for an AI step.',
    inputs: 1,
    outputs: ['main'],
    params: [
      collectionParam,
      { key: 'query', label: 'Question', kind: 'text', default: '{{ $json.text }}' },
      { key: 'topK', label: 'Results', kind: 'number', default: 4 },
      { key: 'minScore', label: 'Minimum score', kind: 'number', default: 0, hint: '0 to 1; 0 keeps every result' },
      credentialParam,
    ],
    run: searchEffect,
    resume: perItemResult('results'),
  },
  {
    type: 'rag.info',
    label: 'Knowledge Base Info',
    group: 'ai',
    description: 'Lists knowledge bases or their sources, or deletes a source or a whole knowledge base.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'sources', options: INFO_OPERATIONS },
      collectionParam,
      { key: 'source', label: 'Source (delete source)', kind: 'text', default: '' },
    ],
    run: infoEffect,
    resume: infoRows,
  },
];
