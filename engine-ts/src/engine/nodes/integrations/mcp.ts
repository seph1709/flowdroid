/**
 * MCP Client: calls a Model Context Protocol server's tools, resources and prompts.
 *
 * The host speaks the protocol (initialize, sessions, JSON-RPC over Streamable
 * HTTP or a stdio process in FlowDroid's Ubuntu); the node only says what to ask:
 *   { type: 'mcp', server: { transport, url, credential } | { transport, command } | { transport: 'saved', credential },
 *     calls: [{ method, params }], timeoutMs }
 *   → { results: [{ result } | { error }] }, or { error } when the server can't be reached.
 */

import { fail } from '../../../errors.ts';
import { parseJson } from '../../../json.ts';
import { getKey, isObj, toNum, toTemplateStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, type NodeRun, type NodeSpec } from '../spec.ts';
import { AUTH_CREDENTIALS } from '../http.ts';
import { credentialParam } from './api.ts';

export const MCP_TRANSPORTS = ['http', 'stdio', 'saved'];
const OPERATIONS: Record<string, string> = {
  callTool: 'tools/call',
  listTools: 'tools/list',
  readResource: 'resources/read',
  listResources: 'resources/list',
  getPrompt: 'prompts/get',
  listPrompts: 'prompts/list',
};

function operation(run: NodeRun): string {
  const op = paramText(run, 'operation', 0);
  if (getKey(OPERATIONS, op) === null) fail('NodeError', `unknown operation ${op}`);
  return op;
}

/** Where the server is; the same for every item. */
function server(run: NodeRun): Obj {
  const transport = paramText(run, 'transport', 0);
  if (transport === 'http') {
    const url = paramText(run, 'url', 0);
    if (!/^https?:\/\//.test(url)) fail('NodeError', 'the server URL must start with http:// or https://');
    const out: Obj = { transport, url };
    const credential = paramText(run, 'credential', 0);
    if (credential !== '') out['credential'] = credential;
    return out;
  }
  if (transport === 'stdio') {
    const command = paramText(run, 'command', 0);
    if (command === '') fail('NodeError', 'command is empty');
    return { transport, command };
  }
  if (transport === 'saved') {
    // An "MCP server" credential: its URL or command, and the key it signs in with.
    const credential = paramText(run, 'server', 0);
    if (credential === '') fail('NodeError', 'choose a saved MCP server');
    return { transport, credential };
  }
  return fail('NodeError', `unknown transport ${transport}`);
}

/** The arguments object; text is parsed as JSON. */
function args(run: NodeRun, index: number): Obj {
  let v = paramValue(run, 'arguments', index);
  if (typeof v === 'string') {
    if (v.trim() === '') return {};
    v = parseJson(v, 'arguments');
  }
  if (!isObj(v)) fail('NodeError', 'arguments must be a JSON object');
  return v;
}

function required(run: NodeRun, key: string, index: number, what: string): string {
  const v = paramText(run, key, index);
  if (v === '') fail('NodeError', `${what} is empty`);
  return v;
}

/** The JSON-RPC request for item [index]. */
function call(run: NodeRun, op: string, index: number): Obj {
  const method = toTemplateStr(getKey(OPERATIONS, op));
  switch (op) {
    case 'callTool':
      return { method, params: { name: required(run, 'name', index, 'tool name'), arguments: args(run, index) } };
    case 'getPrompt':
      return { method, params: { name: required(run, 'name', index, 'prompt name'), arguments: args(run, index) } };
    case 'readResource':
      return { method, params: { uri: required(run, 'uri', index, 'resource URI') } };
    default:
      return { method, params: {} };
  }
}

function run(run: NodeRun): { effect: Obj } {
  const op = operation(run);
  const srv = server(run);
  const calls = itemsOf(run).map((_, i) => call(run, op, i));
  const timeout = toNum(paramValue(run, 'timeout', 0));
  return { effect: { type: 'mcp', server: srv, calls, timeoutMs: (timeout >= 1 ? timeout : 1) * 1000 } };
}

/** The text blocks of an MCP content list, joined. */
function textOf(list: Val): string {
  if (!Array.isArray(list)) return '';
  return list
    .filter((b) => isObj(b) && typeof getKey(b, 'text') === 'string')
    .map((b) => toTemplateStr(getKey(b as Obj, 'text')))
    .join('\n');
}

function toItem(op: string, result: Obj): Item {
  switch (op) {
    case 'callTool': {
      const text = textOf(getKey(result, 'content'));
      if (getKey(result, 'isError') === true) fail('NodeError', `the tool failed: ${text === '' ? 'no details' : text}`);
      const item: Item = { text, content: getKey(result, 'content') };
      const structured = getKey(result, 'structuredContent');
      if (structured !== null) item['json'] = structured;
      return item;
    }
    case 'readResource':
      return { text: textOf(getKey(result, 'contents')), contents: getKey(result, 'contents') };
    default:
      return result;
  }
}

function resume(run: NodeRun, result: Obj): Item[][] {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const results = getKey(result, 'results');
  if (!Array.isArray(results)) fail('NodeError', 'the MCP server returned no result');
  const op = operation(run);
  return [results.map((r) => {
    if (!isObj(r)) return fail('NodeError', 'the MCP server returned no result');
    const failed = getKey(r, 'error');
    if (typeof failed === 'string') fail('NodeError', `MCP: ${failed}`);
    const body = getKey(r, 'result');
    if (!isObj(body)) fail('NodeError', 'the MCP server returned no result');
    return toItem(op, body);
  })];
}

export const mcpNodes: NodeSpec[] = [
  {
    type: 'mcp.client',
    label: 'MCP Client',
    group: 'ai',
    description: 'Calls a tool, reads a resource or gets a prompt from an MCP server, on the web or run in Ubuntu.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'transport', label: 'Server type', kind: 'select', default: 'http', options: MCP_TRANSPORTS },
      { key: 'server', label: 'Saved server', kind: 'credential', default: '', options: ['mcpServer'], hint: 'add one in Settings → Credentials → MCP server' },
      { key: 'url', label: 'Server URL', kind: 'text', default: '', hint: 'e.g. https://example.com/mcp' },
      { ...credentialParam(AUTH_CREDENTIALS), label: 'Authentication', hint: 'empty = none' },
      { key: 'command', label: 'Command', kind: 'text', default: '', hint: 'runs in Ubuntu, e.g. npx -y @modelcontextprotocol/server-everything' },
      { key: 'operation', label: 'Operation', kind: 'select', default: 'callTool', options: Object.keys(OPERATIONS) },
      { key: 'name', label: 'Tool or prompt', kind: 'text', default: '' },
      { key: 'uri', label: 'Resource URI', kind: 'text', default: '' },
      { key: 'arguments', label: 'Arguments', kind: 'json', default: '{}' },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: 60 },
    ],
    run,
    resume,
  },
];
