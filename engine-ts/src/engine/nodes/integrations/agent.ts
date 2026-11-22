/**
 * AI Agent: Claude works on each item with tools it may call (HTTP, shell
 * commands, other workflows, phone tables, web search) until it has an answer.
 *
 * Each turn is a round trip to the host: an `http` effect to ask Claude,
 * then a `tools` effect to run the tools it asked for:
 *   { type: 'tools', calls: [{ id, kind, name, config, input }] }
 *   → { results: [{ content: string, isError: bool }] }
 * The conversation so far travels in the effect's memo.
 */

import { fail } from '../../../errors.ts';
import { getKey, isObj, toNum, toTemplateStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, rows, type NodeResult, type NodeRun, type NodeSpec, type StepResult } from '../spec.ts';
import { ANTHROPIC_VERSION, DEFAULT_CLAUDE_MODEL } from './ai.ts';
import { apiRequest, checkResponse, credentialParam } from './api.ts';

export const TOOL_KINDS = ['http', 'command', 'workflow', 'table'];
const TOOL_NAME = /^[A-Za-z0-9_-]{1,64}$/;
const HTTP_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

interface Tool {
  kind: string;
  name: string;
  description: string;
  config: string;
}

/** The tools the node is set up with, checked. */
function tools(run: NodeRun): Tool[] {
  const seen = new Set<string>();
  return rows(run, 'tools').map((row, i) => {
    const kind = toTemplateStr(getKey(row, 'kind'));
    if (!TOOL_KINDS.includes(kind)) fail('NodeError', `tool ${i + 1}: unknown kind ${kind}`);
    const name = toTemplateStr(getKey(row, 'name'));
    if (!TOOL_NAME.test(name)) fail('NodeError', `tool name "${name}" must be 1–64 letters, digits, _ or -`);
    if (seen.has(name)) fail('NodeError', `two tools are named ${name}`);
    seen.add(name);
    return { kind, name, description: toTemplateStr(getKey(row, 'description')), config: toTemplateStr(getKey(row, 'config')) };
  });
}

function toolSchema(tool: Tool): Obj {
  const obj = (properties: Obj, required: string[]): Obj => ({ type: 'object', properties, required });
  switch (tool.kind) {
    case 'http': {
      const url = tool.config === '' ? 'The full URL.' : `The full URL; it must start with ${tool.config}`;
      return obj(
        {
          method: { type: 'string', enum: HTTP_METHODS },
          url: { type: 'string', description: url },
          body: { type: 'string', description: 'Request body, usually JSON.' },
        },
        ['url'],
      );
    }
    case 'command':
      return obj({ command: { type: 'string', description: 'A shell command; its output is returned.' } }, ['command']);
    case 'workflow':
      return obj({ input: { type: 'object', description: 'Data the workflow receives as its item.' } }, []);
    default:
      return obj(
        {
          operation: { type: 'string', enum: ['find', 'insert', 'update', 'delete'] },
          where: { type: 'object', description: 'Column: value pairs a row must match.' },
          row: { type: 'object', description: 'Values to insert, or to set on matching rows.' },
        },
        ['operation'],
      );
  }
}

const DEFAULT_DESCRIPTIONS: Record<string, string> = {
  http: 'Calls a web API and returns the response.',
  command: 'Runs a shell command and returns what it printed.',
  workflow: 'Runs a FlowDroid workflow and returns its output.',
  table: 'Reads or changes rows in a table stored on the phone.',
};

function apiTools(run: NodeRun): Obj[] {
  const list: Obj[] = tools(run).map((t) => ({
    name: t.name,
    description: t.description === '' ? (DEFAULT_DESCRIPTIONS[t.kind] ?? '') : t.description,
    input_schema: toolSchema(t),
  }));
  if (getKey(run.params, 'webSearch') === true) list.push({ type: 'web_search_20260209', name: 'web_search' });
  return list;
}

function maxSteps(run: NodeRun): number {
  const n = Math.trunc(toNum(paramValue(run, 'maxSteps', 0)));
  return n >= 1 ? n : 1;
}

/** One call to Claude with the conversation so far. */
function ask(run: NodeRun, index: number, messages: Val[]): Obj {
  const model = paramText(run, 'model', index);
  const system = paramText(run, 'system', index);
  const timeout = toNum(paramValue(run, 'timeout', index));
  const body: Obj = { model: model === '' ? DEFAULT_CLAUDE_MODEL : model, max_tokens: 16000 };
  if (system !== '') body['system'] = system;
  body['messages'] = messages;
  const toolList = apiTools(run);
  if (toolList.length > 0) body['tools'] = toolList;
  body['thinking'] = { type: 'adaptive' };
  body['fallbacks'] = 'default';
  return apiRequest(run, {
    method: 'POST',
    url: 'https://api.anthropic.com/v1/messages',
    headers: {
      'x-api-key': '{cred:apiKey}',
      'anthropic-version': ANTHROPIC_VERSION,
      'anthropic-beta': 'server-side-fallback-2026-07-01',
    },
    body,
    timeoutMs: (timeout >= 1 ? timeout : 1) * 1000,
  });
}

interface Memo {
  index: number;
  messages: Val[];
  steps: number;
  outputs: Item[];
}

function toMemo(memo: Memo, extra: Obj = {}): Obj {
  return { index: memo.index, messages: memo.messages, steps: memo.steps, outputs: memo.outputs, ...extra };
}

function fromMemo(v: Val): Memo & { phase: string; calls: Val[] } {
  if (!isObj(v)) return fail('NodeError', 'the agent lost its place');
  const list = (key: string): Val[] => {
    const x = getKey(v, key);
    return Array.isArray(x) ? x : [];
  };
  return {
    index: toNum(getKey(v, 'index')),
    messages: list('messages'),
    steps: toNum(getKey(v, 'steps')),
    outputs: list('outputs').filter(isObj),
    phase: toTemplateStr(getKey(v, 'phase')),
    calls: list('calls'),
  };
}

/** Starts the conversation for item [index]. */
function begin(run: NodeRun, index: number, outputs: Item[]): StepResult {
  const prompt = paramText(run, 'prompt', index);
  if (prompt === '') fail('NodeError', 'prompt is empty');
  const messages: Val[] = [{ role: 'user', content: prompt }];
  const memo: Memo = { index, messages, steps: 1, outputs };
  return { effect: { type: 'http', requests: [ask(run, index, messages)] }, memo: toMemo(memo, { phase: 'model' }) };
}

/** Asks Claude again, unless the step budget is spent. */
function askAgain(run: NodeRun, memo: Memo): StepResult {
  const limit = maxSteps(run);
  if (memo.steps >= limit) fail('NodeError', `stopped after ${limit} steps without a final answer`);
  const next = { ...memo, steps: memo.steps + 1 };
  return {
    effect: { type: 'http', requests: [ask(run, memo.index, memo.messages)] },
    memo: toMemo(next, { phase: 'model' }),
  };
}

function textOf(content: Val[]): string {
  return content
    .filter((b) => isObj(b) && getKey(b, 'type') === 'text')
    .map((b) => toTemplateStr(getKey(b as Obj, 'text')))
    .join('');
}

function start(run: NodeRun): NodeResult {
  tools(run);
  return begin(run, 0, []);
}

function step(run: NodeRun, result: Obj): StepResult {
  const memo = fromMemo(run.memo);
  if (memo.phase === 'tools') {
    const results = getKey(result, 'results');
    const error = getKey(result, 'error');
    if (typeof error === 'string') fail('NodeError', error);
    if (!Array.isArray(results) || results.length !== memo.calls.length) {
      fail('NodeError', `expected ${memo.calls.length} tool results`);
    }
    const content = memo.calls.map((id, i) => {
      const r = results[i];
      const block: Obj = { type: 'tool_result', tool_use_id: id, content: toTemplateStr(isObj(r) ? getKey(r, 'content') : r) };
      if (isObj(r) && getKey(r, 'isError') === true) block['is_error'] = true;
      return block;
    });
    return askAgain(run, { ...memo, messages: [...memo.messages, { role: 'user', content }] });
  }

  const responses = getKey(result, 'responses');
  if (!Array.isArray(responses) || responses.length === 0) fail('NodeError', 'Claude returned no response');
  const body = checkResponse('Claude', responses[0] ?? null);
  if (!isObj(body)) fail('NodeError', 'Claude returned no message');
  const stop = getKey(body, 'stop_reason');
  if (stop === 'refusal') fail('NodeError', 'Claude declined this request');
  const raw = getKey(body, 'content');
  const content = Array.isArray(raw) ? raw : [];
  const messages = [...memo.messages, { role: 'assistant', content }];

  if (stop === 'tool_use') {
    const known = new Map(tools(run).map((t) => [t.name, t]));
    const uses = content.filter((b): b is Obj => isObj(b) && getKey(b, 'type') === 'tool_use');
    const calls = uses.map((u) => {
      const name = toTemplateStr(getKey(u, 'name'));
      const tool = known.get(name);
      return { id: getKey(u, 'id'), kind: tool?.kind ?? '', name, config: tool?.config ?? '', input: getKey(u, 'input') };
    });
    return {
      effect: { type: 'tools', calls },
      memo: toMemo({ ...memo, messages }, { phase: 'tools', calls: calls.map((c) => c.id) }),
    };
  }
  if (stop === 'pause_turn') return askAgain(run, { ...memo, messages });

  const outputs = [...memo.outputs, { text: textOf(content), steps: memo.steps, stopReason: stop }];
  const next = memo.index + 1;
  if (next < itemsOf(run).length) return begin(run, next, outputs);
  return { outputs: [outputs] };
}

export const agentNodes: NodeSpec[] = [
  {
    type: 'ai.agent',
    label: 'AI Agent',
    group: 'ai',
    description: 'Claude works on each item using the tools you give it (web APIs, commands, workflows, phone tables, web search) until it has an answer.',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['anthropic']),
      { key: 'model', label: 'Model', kind: 'text', default: '', hint: `empty = ${DEFAULT_CLAUDE_MODEL}` },
      { key: 'system', label: 'Instructions', kind: 'text', default: '' },
      { key: 'prompt', label: 'Task', kind: 'text', default: '{{ $json.text }}' },
      { key: 'tools', label: 'Tools', kind: 'tools', default: [] },
      { key: 'webSearch', label: 'Let it search the web', kind: 'boolean', default: false },
      { key: 'maxSteps', label: 'Most steps', kind: 'number', default: 10 },
      { key: 'timeout', label: 'Timeout per step (seconds)', kind: 'number', default: 120 },
    ],
    run: start,
    step,
  },
];
