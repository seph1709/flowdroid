/**
 * AI Agent: Claude works on each item with tools it may call (HTTP, shell
 * commands, other workflows, phone tables, web search) until it has an answer.
 *
 * Each turn is a round trip to the host: an `http` effect to ask Claude,
 * then a `tools` effect to run the tools it asked for:
 *   { type: 'tools', calls: [{ id, kind, name, config, input }] }
 *   → { results: [{ content: string, isError: bool }] }
 * The conversation so far travels in the effect's memo.
 *
 * A `browser` tool drives the phone's in-app browser (config: the sites it may
 * visit); each action returns the page as it is now, with numbered elements.
 *
 * `mcp` tools are MCP servers (a saved server's name, a URL or a command):
 * before the first turn one `mcpList` effect asks the host for their tools,
 *   { type: 'mcpList', servers: [{ name, config }], timeoutMs }
 *   → { results: [{ tools: [{ name, description, inputSchema }] } | { error }] }
 * and each becomes a tool named `<server>__<tool>`; its calls go out in the
 * `tools` effect with `kind: 'mcp'` and the server's own `tool` name.
 *
 * With the `claudeCode` provider, Claude Code runs the whole task in FlowDroid's
 * Ubuntu with its own tools (files, shell, web, MCP servers), signed in with
 * the person's own account: one `cliChat` effect with `mode: 'agent'` per run.
 */

import { fail } from '../../../errors.ts';
import { parseJson } from '../../../json.ts';
import { getKey, isObj, toNum, toTemplateStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, rows, type NodeResult, type NodeRun, type NodeSpec, type StepResult } from '../spec.ts';
import { ANTHROPIC_VERSION, DEFAULT_CLAUDE_MODEL } from './ai.ts';
import { apiRequest, checkResponse, credentialParam } from './api.ts';

export const TOOL_KINDS = ['http', 'command', 'workflow', 'table', 'mcp', 'browser'];
const BROWSER_ACTIONS = ['open', 'read', 'click', 'type', 'press', 'scroll', 'back'];
const TOOL_NAME = /^[A-Za-z0-9_-]{1,64}$/;
const HTTP_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

const PROVIDERS = ['anthropic', 'claudeCode'];
/** What Claude Code may do without asking; each level includes the one before. */
const ACCESS = ['readFiles', 'editFiles', 'runCommands'];
const ACCESS_TOOLS: Record<string, string[]> = {
  readFiles: ['Read', 'Glob', 'Grep'],
  editFiles: ['Read', 'Glob', 'Grep', 'Edit', 'Write'],
  runCommands: ['Read', 'Glob', 'Grep', 'Edit', 'Write', 'Bash'],
};

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
    case 'browser': {
      const sites = tool.config === '' ? '' : ` Only these sites: ${tool.config}.`;
      return obj(
        {
          action: { type: 'string', enum: BROWSER_ACTIONS },
          url: { type: 'string', description: `For open: the page to load.${sites}` },
          target: { type: 'string', description: 'For click and type: an element number from the last page view, like "12", or a CSS selector.' },
          text: { type: 'string', description: 'For type: the text to enter. For press: a key, like Enter.' },
        },
        ['action'],
      );
    }
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
  browser: 'Uses a web browser on the phone, with your saved logins: open a page, then click, type and scroll. Every action returns the page as it is now, with numbered elements to use as targets.',
};

/** The node's own tools, then the MCP servers' tools, then web search. */
function apiTools(run: NodeRun, mcp: Val[]): Obj[] {
  const list: Obj[] = tools(run).filter((t) => t.kind !== 'mcp').map((t) => ({
    name: t.name,
    description: t.description === '' ? (DEFAULT_DESCRIPTIONS[t.kind] ?? '') : t.description,
    input_schema: toolSchema(t),
  }));
  for (const t of mcp) {
    if (!isObj(t)) continue;
    list.push({ name: getKey(t, 'name'), description: getKey(t, 'description'), input_schema: getKey(t, 'input_schema') });
  }
  if (getKey(run.params, 'webSearch') === true) list.push({ type: 'web_search_20260209', name: 'web_search' });
  return list;
}

function maxSteps(run: NodeRun): number {
  const n = Math.trunc(toNum(paramValue(run, 'maxSteps', 0)));
  return n >= 1 ? n : 1;
}

/** One call to Claude with the conversation so far. */
function ask(run: NodeRun, index: number, messages: Val[], mcp: Val[]): Obj {
  const model = paramText(run, 'model', index);
  const system = paramText(run, 'system', index);
  const timeout = toNum(paramValue(run, 'timeout', index));
  const body: Obj = { model: model === '' ? DEFAULT_CLAUDE_MODEL : model, max_tokens: 16000 };
  if (system !== '') body['system'] = system;
  body['messages'] = messages;
  const toolList = apiTools(run, mcp);
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
  /** The MCP servers' tools, found before the first turn. */
  mcp: Val[];
}

function toMemo(memo: Memo, extra: Obj = {}): Obj {
  return { index: memo.index, messages: memo.messages, steps: memo.steps, outputs: memo.outputs, mcp: memo.mcp, ...extra };
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
    mcp: list('mcp'),
    phase: toTemplateStr(getKey(v, 'phase')),
    calls: list('calls'),
  };
}

/** Starts the conversation for item [index]. */
function begin(run: NodeRun, index: number, outputs: Item[], mcp: Val[]): StepResult {
  const prompt = paramText(run, 'prompt', index);
  if (prompt === '') fail('NodeError', 'prompt is empty');
  const messages: Val[] = [{ role: 'user', content: prompt }];
  const memo: Memo = { index, messages, steps: 1, outputs, mcp };
  return { effect: { type: 'http', requests: [ask(run, index, messages, mcp)] }, memo: toMemo(memo, { phase: 'model' }) };
}

/** Asks the host for the MCP servers' tools before the first turn. */
function discover(run: NodeRun, servers: Tool[]): StepResult {
  const timeout = toNum(paramValue(run, 'timeout', 0));
  const memo: Memo = { index: 0, messages: [], steps: 0, outputs: [], mcp: [] };
  return {
    effect: {
      type: 'mcpList',
      servers: servers.map((t) => ({ name: t.name, config: t.config })),
      timeoutMs: (timeout >= 1 ? timeout : 1) * 1000,
    },
    memo: toMemo(memo, { phase: 'discover' }),
  };
}

/** `<server>__<tool>`, as a name Claude accepts. */
function mcpToolName(server: string, tool: string): string {
  return `${server}__${tool}`.replace(/[^A-Za-z0-9_-]/gu, '_').slice(0, 64);
}

/** The MCP servers' tools, then the first item's first turn. */
function afterDiscover(run: NodeRun, result: Obj): StepResult {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const all = tools(run);
  const servers = all.filter((t) => t.kind === 'mcp');
  const results = getKey(result, 'results');
  if (!Array.isArray(results) || results.length !== servers.length) fail('NodeError', `expected ${servers.length} MCP tool lists`);
  const used = new Set(all.filter((t) => t.kind !== 'mcp').map((t) => t.name));
  const mcp: Val[] = [];
  servers.forEach((server, i) => {
    const r = results[i] ?? null;
    if (!isObj(r)) return fail('NodeError', `MCP tool ${server.name}: no tool list`);
    const failed = getKey(r, 'error');
    if (typeof failed === 'string') fail('NodeError', `MCP tool ${server.name}: ${failed}`);
    const list = getKey(r, 'tools');
    for (const t of Array.isArray(list) ? list : []) {
      if (!isObj(t)) continue;
      const tool = toTemplateStr(getKey(t, 'name'));
      if (tool === '') continue;
      const name = mcpToolName(server.name, tool);
      if (used.has(name)) continue;
      used.add(name);
      const description = getKey(t, 'description');
      const schema = getKey(t, 'inputSchema');
      mcp.push({
        name,
        server: server.name,
        config: server.config,
        tool,
        description: typeof description === 'string' && description !== '' ? description : `${tool} from the ${server.name} MCP server`,
        input_schema: isObj(schema) ? schema : { type: 'object', properties: {} },
      });
    }
  });
  return begin(run, 0, [], mcp);
}

/** Asks Claude again, unless the step budget is spent. */
function askAgain(run: NodeRun, memo: Memo): StepResult {
  const limit = maxSteps(run);
  if (memo.steps >= limit) fail('NodeError', `stopped after ${limit} steps without a final answer`);
  const next = { ...memo, steps: memo.steps + 1 };
  return {
    effect: { type: 'http', requests: [ask(run, memo.index, memo.messages, memo.mcp)] },
    memo: toMemo(next, { phase: 'model' }),
  };
}

function textOf(content: Val[]): string {
  return content
    .filter((b) => isObj(b) && getKey(b, 'type') === 'text')
    .map((b) => toTemplateStr(getKey(b as Obj, 'text')))
    .join('');
}

function provider(run: NodeRun): string {
  const p = paramText(run, 'provider', 0);
  if (!PROVIDERS.includes(p)) fail('NodeError', `unknown provider ${p}`);
  return p;
}

/** Claude Code's MCP servers, `{name: settings}` as in its own `.mcp.json`. */
function mcpServers(run: NodeRun): Obj {
  let v = paramValue(run, 'mcpServers', 0);
  if (typeof v === 'string') v = v.trim() === '' ? {} : parseJson(v, 'MCP servers');
  if (!isObj(v)) return fail('NodeError', 'MCP servers must be a JSON object of name: settings');
  for (const name of Object.keys(v)) {
    if (!TOOL_NAME.test(name)) fail('NodeError', `MCP server name "${name}" must be 1–64 letters, digits, _ or -`);
    if (!isObj(getKey(v, name))) fail('NodeError', `MCP server ${name} must be an object`);
  }
  return v;
}

/** The tools Claude Code may use without asking. */
function allowedTools(run: NodeRun, servers: Obj): string[] {
  const access = paramText(run, 'access', 0);
  const base = ACCESS.includes(access) ? ACCESS_TOOLS[access] : undefined;
  if (base === undefined) return fail('NodeError', `unknown access ${access}`);
  const list = [...base];
  if (getKey(run.params, 'webSearch') === true) list.push('WebSearch', 'WebFetch');
  for (const name of Object.keys(servers)) list.push(`mcp__${name}`);
  return list;
}

/** One task for Claude Code; the host runs it in Ubuntu and returns the result. */
function cliTask(run: NodeRun, index: number, servers: Obj, allowed: string[]): Obj {
  const prompt = paramText(run, 'prompt', index);
  if (prompt === '') fail('NodeError', 'prompt is empty');
  const folder = paramText(run, 'folder', index);
  if (!folder.startsWith('/')) fail('NodeError', 'folder must be a path in Ubuntu, starting with /');
  const timeout = toNum(paramValue(run, 'timeout', index));
  const steps = maxSteps(run);
  const session = paramText(run, 'session', index);
  const workflow = getKey(run.base, '$workflow');
  const scope = isObj(workflow) ? toTemplateStr(getKey(workflow, 'id')) : '';
  return {
    mode: 'agent',
    prompt,
    system: paramText(run, 'system', index),
    model: paramText(run, 'model', index),
    image: '',
    folder,
    tools: allowed,
    mcpServers: servers,
    maxTurns: steps,
    // A conversation key continues the same Claude Code session across runs of this step.
    session: session === '' ? '' : `${scope}/${run.node.name}/${session}`,
    timeoutMs: (timeout >= 1 ? timeout : 1) * 1000 * steps,
  };
}

function startClaudeCode(run: NodeRun): NodeResult {
  const servers = mcpServers(run);
  const allowed = allowedTools(run, servers);
  const chats = itemsOf(run).map((_, i) => cliTask(run, i, servers, allowed));
  return { effect: { type: 'cliChat', agent: 'claudeCode', chats } };
}

/** Claude Code's results, one per task: `{text, model, sessionId, steps, stopReason, costUsd}` or `{error}`. */
function finishClaudeCode(run: NodeRun, result: Obj): StepResult {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const replies = getKey(result, 'replies');
  if (!Array.isArray(replies)) fail('NodeError', 'Claude Code returned no result');
  const outputs = replies.map((reply, i): Item => {
    if (!isObj(reply)) return fail('NodeError', 'Claude Code returned no result');
    const failed = getKey(reply, 'error');
    if (typeof failed === 'string') fail('NodeError', `Claude Code: ${failed}`);
    const str = (key: string): string => {
      const v = getKey(reply, key);
      return typeof v === 'string' ? v : '';
    };
    const model = str('model');
    return {
      text: str('text'),
      steps: toNum(getKey(reply, 'steps')),
      stopReason: str('stopReason'),
      provider: 'claudeCode',
      model: model === '' ? paramText(run, 'model', i) : model,
      sessionId: str('sessionId'),
      costUsd: toNum(getKey(reply, 'costUsd')),
    };
  });
  return { outputs: [outputs] };
}

function start(run: NodeRun): NodeResult {
  if (provider(run) === 'claudeCode') return startClaudeCode(run);
  const servers = tools(run).filter((t) => t.kind === 'mcp');
  if (servers.length > 0) return discover(run, servers);
  return begin(run, 0, [], []);
}

function step(run: NodeRun, result: Obj): StepResult {
  if (provider(run) === 'claudeCode') return finishClaudeCode(run, result);
  const memo = fromMemo(run.memo);
  if (memo.phase === 'discover') return afterDiscover(run, result);
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
    const known = new Map(tools(run).filter((t) => t.kind !== 'mcp').map((t) => [t.name, t]));
    const fromMcp = new Map(memo.mcp.filter(isObj).map((t) => [toTemplateStr(getKey(t, 'name')), t]));
    const uses = content.filter((b): b is Obj => isObj(b) && getKey(b, 'type') === 'tool_use');
    const calls = uses.map((u): Obj => {
      const name = toTemplateStr(getKey(u, 'name'));
      const remote = fromMcp.get(name);
      if (remote !== undefined) {
        return { id: getKey(u, 'id'), kind: 'mcp', name, config: getKey(remote, 'config'), input: getKey(u, 'input'), tool: getKey(remote, 'tool') };
      }
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
  if (next < itemsOf(run).length) return begin(run, next, outputs, memo.mcp);
  return { outputs: [outputs] };
}

export const agentNodes: NodeSpec[] = [
  {
    type: 'ai.agent',
    label: 'AI Agent',
    group: 'ai',
    description: 'Claude works on each item using the tools you give it (web APIs, commands, workflows, phone tables, web search) until it has an answer, or Claude Code does it in Ubuntu with your own Claude plan.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'provider', label: 'Provider', kind: 'select', default: 'anthropic', options: PROVIDERS },
      credentialParam(['anthropic']),
      { key: 'model', label: 'Model', kind: 'text', default: '', hint: `empty = ${DEFAULT_CLAUDE_MODEL}, or Claude Code's own default` },
      { key: 'system', label: 'Instructions', kind: 'text', default: '' },
      { key: 'prompt', label: 'Task', kind: 'text', default: '{{ $json.text }}' },
      { key: 'tools', label: 'Tools', kind: 'tools', default: [], hint: 'an mcp tool takes a saved MCP server’s name, a URL or a command, and brings all its tools; a browser tool takes the sites it may visit' },
      { key: 'access', label: 'Claude Code may', kind: 'select', default: 'readFiles', options: ACCESS },
      { key: 'folder', label: 'Folder', kind: 'text', default: '/root/files', hint: 'where Claude Code works, in Ubuntu' },
      { key: 'mcpServers', label: 'MCP servers', kind: 'json', default: '{}', hint: 'Claude Code’s .mcp.json servers, e.g. {"docs": {"type": "http", "url": "https://…/mcp"}}' },
      { key: 'session', label: 'Conversation key', kind: 'text', default: '', hint: 'same key = Claude Code continues that conversation, e.g. {{ $json.chatId }}' },
      { key: 'webSearch', label: 'Let it search the web', kind: 'boolean', default: false },
      { key: 'maxSteps', label: 'Most steps', kind: 'number', default: 10 },
      { key: 'timeout', label: 'Timeout per step (seconds)', kind: 'number', default: 120 },
    ],
    run: start,
    step,
  },
];
