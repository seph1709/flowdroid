/**
 * HTTP Request: the core describes each request as an effect; the host sends
 * them and returns one response per item:
 *   { responses: [{ status, headers, body } | { error }] }
 */

import { fail } from '../../errors.ts';
import { parseJson } from '../../json.ts';
import {
  formatNumber, getKey, isObj, setKey, stringify, toNum, toTemplateStr, type Obj, type Val,
} from '../../value.ts';
import { render } from '../../expression/template.ts';
import type { Item } from '../context.ts';
import { credentialParam } from './integrations/api.ts';
import { filePath, mimeFromPath } from './file_refs.ts';
import { ctxFor, itemsOf, paramText, paramValue, rows, type NodeRun, type NodeSpec } from './spec.ts';

const DEFAULT_TIMEOUT_SECONDS = 30;

/** Credential types HTTP Request can authenticate with. */
export const AUTH_CREDENTIALS = ['headerAuth', 'bearerAuth', 'basicAuth', 'oauth2', 'webSession'];

function buildRequest(run: NodeRun, index: number): Obj {
  const url = paramText(run, 'url', index);
  if (url === '') fail('NodeError', 'URL is required');
  const ctx = ctxFor(run, index);
  const headers: Obj = {};
  for (const row of rows(run, 'headers')) {
    const name = toTemplateStr(render(getKey(row, 'name'), ctx));
    if (name !== '') setKey(headers, name, toTemplateStr(render(getKey(row, 'value'), ctx)));
  }
  const timeout = toNum(paramValue(run, 'timeout', index));
  const sendFile = filePath(run, 'sendFile', index);
  const hasType = Object.keys(headers).some((name) => name.toLowerCase() === 'content-type');
  if (sendFile !== '' && !hasType) setKey(headers, 'Content-Type', mimeFromPath(sendFile));
  const request: Obj = {
    method: paramText(run, 'method', index).toUpperCase(),
    url,
    headers,
    body: sendFile !== '' ? null : requestBody(paramValue(run, 'body', index), headers),
    timeoutMs: (timeout > 0 ? timeout : DEFAULT_TIMEOUT_SECONDS) * 1000,
  };
  // The host sends the file's bytes as the body, or saves the response as a file.
  if (sendFile !== '') request['file'] = sendFile;
  if (getKey(run.params, 'responseFormat') === 'file') request['saveAs'] = 'file';
  // The host adds the credential's header (API key, bearer token, basic auth or OAuth2) when sending.
  const credential = paramText(run, 'credential', index);
  if (credential !== '') {
    request['credential'] = credential;
    request['auth'] = true;
  }
  return request;
}

/** Text bodies are sent as is; structured ones as JSON, with a content type unless one is set. */
function requestBody(body: Val, headers: Obj): Val {
  if (body === null || body === '') return null;
  if (typeof body === 'string') return body;
  const hasType = Object.keys(headers).some((name) => name.toLowerCase() === 'content-type');
  if (!hasType) setKey(headers, 'Content-Type', 'application/json');
  return stringify(body);
}

function toItems(run: NodeRun, response: Val): Item[] {
  if (!isObj(response)) fail('NodeError', 'response must be an object');
  const error = getKey(response, 'error');
  if (typeof error === 'string') fail('NodeError', `request failed: ${error}`);
  const status = toNum(getKey(response, 'status'));
  if (status >= 400 && getKey(run.params, 'ignoreHttpErrors') !== true) {
    fail('NodeError', `request failed with status ${formatNumber(status)}`);
  }
  const text = toTemplateStr(getKey(response, 'body'));
  const format = getKey(run.params, 'responseFormat');
  if (format === 'file') {
    // The host saved the bytes and answers with the file's reference.
    const ref = parseOrText(text);
    const file = isObj(ref) ? ref : null;
    if (getKey(run.params, 'fullResponse') === true) {
      const headers = getKey(response, 'headers');
      return [{ statusCode: status, headers: isObj(headers) ? headers : {}, file }];
    }
    return [{ file }];
  }
  const body = format === 'text' ? text : parseOrText(text);
  if (getKey(run.params, 'fullResponse') === true) {
    const headers = getKey(response, 'headers');
    return [{ statusCode: status, headers: isObj(headers) ? headers : {}, body }];
  }
  if (Array.isArray(body)) return body.map((entry) => (isObj(entry) ? entry : { data: entry }));
  return [isObj(body) ? body : { data: body }];
}

function parseOrText(text: string): Val {
  try {
    return parseJson(text, 'response body');
  } catch {
    return text;
  }
}

export const httpNodes: NodeSpec[] = [
  {
    type: 'http.request',
    label: 'HTTP Request',
    group: 'network',
    description: 'Calls a URL once per item and outputs the response.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'method', label: 'Method', kind: 'select', default: 'GET', options: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'] },
      { ...credentialParam(AUTH_CREDENTIALS), label: 'Authentication', hint: 'empty = none' },
      { key: 'url', label: 'URL', kind: 'text', default: '', hint: 'https://api.example.com/{{ $json.id }}' },
      { key: 'headers', label: 'Headers', kind: 'keyValues', default: [] },
      { key: 'body', label: 'Body', kind: 'json', default: '' },
      { key: 'sendFile', label: 'Send a file as the body', kind: 'text', default: '', hint: 'e.g. {{ $json.file.path }}; replaces Body' },
      { key: 'responseFormat', label: 'Response format', kind: 'select', default: 'json', options: ['json', 'text', 'file'] },
      { key: 'fullResponse', label: 'Include status and headers', kind: 'boolean', default: false },
      { key: 'ignoreHttpErrors', label: 'Continue on 4xx/5xx', kind: 'boolean', default: false },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: DEFAULT_TIMEOUT_SECONDS },
    ],
    run: (run) => ({ effect: { type: 'http', requests: itemsOf(run).map((_, i) => buildRequest(run, i)) } }),
    resume: (run, result) => {
      const responses = getKey(result, 'responses');
      const items = itemsOf(run);
      if (!Array.isArray(responses) || responses.length !== items.length) {
        fail('NodeError', `expected ${items.length} responses`);
      }
      return [responses.flatMap((response) => toItems(run, response))];
    },
  },
];
