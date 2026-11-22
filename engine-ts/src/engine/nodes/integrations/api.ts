/**
 * Shared plumbing for nodes that call a third-party API.
 *
 * Such nodes describe their calls as an `http` effect, like HTTP Request,
 * and name a stored credential instead of carrying secrets. The host fills
 * `{cred:field}` (or `{cred:field|default}`) placeholders in the URL, header
 * values and body from that credential, so keys never enter the engine,
 * the execution state or the run history.
 */

import { fail } from '../../../errors.ts';
import { parseJson } from '../../../json.ts';
import { formatNumber, getKey, isObj, setKey, stringify, toNum, toStr, toTemplateStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, type NodeRun, type ParamSpec } from '../spec.ts';

export const DEFAULT_API_TIMEOUT_MS = 60_000;

export interface ApiCall {
  method: string;
  url: string;
  headers?: Obj;
  /** Objects and lists are sent as JSON; text as is; null for no body. */
  body?: Val;
  timeoutMs?: number;
}

export function credentialParam(types: string[]): ParamSpec {
  return { key: 'credential', label: 'Credential', kind: 'credential', default: '', options: types };
}

/** The credential the node is set to use; every API node needs one. */
export function credentialName(run: NodeRun): string {
  const name = paramText(run, 'credential', 0);
  if (name === '') fail('NodeError', 'choose a credential');
  return name;
}

/** One request of an `http` effect, carrying the credential name for the host. */
export function apiRequest(run: NodeRun, call: ApiCall): Obj {
  const headers: Obj = {};
  for (const key of Object.keys(call.headers ?? {})) setKey(headers, key, getKey(call.headers ?? {}, key));
  let body: Val = null;
  if (typeof call.body === 'string') {
    body = call.body;
  } else if (call.body !== undefined && call.body !== null) {
    setKey(headers, 'Content-Type', 'application/json');
    body = stringify(call.body);
  }
  return {
    method: call.method,
    url: call.url,
    headers,
    body,
    timeoutMs: call.timeoutMs ?? DEFAULT_API_TIMEOUT_MS,
    credential: credentialName(run),
  };
}

export function apiEffect(requests: Obj[]): { effect: Obj } {
  return { effect: { type: 'http', requests } };
}

/** One request per input item, built by [build]. */
export function perItem(run: NodeRun, build: (index: number) => Obj): { effect: Obj } {
  return apiEffect(itemsOf(run).map((_, i) => build(i)));
}

/**
 * Turns the host's responses into items: [map] receives each successful
 * response's parsed body and the index of the request that produced it.
 */
export function apiResume(service: string, map: (body: Val, index: number, run: NodeRun) => Item[]) {
  return (run: NodeRun, result: Obj): Item[][] => {
    const responses = getKey(result, 'responses');
    if (!Array.isArray(responses)) fail('NodeError', `${service} returned no response`);
    return [responses.flatMap((response, i) => map(checkResponse(service, response), i, run))];
  };
}

/** The parsed body of a successful response; fails with the service's own message otherwise. */
export function checkResponse(service: string, response: Val): Val {
  if (!isObj(response)) fail('NodeError', `${service} returned no response`);
  const error = getKey(response, 'error');
  if (typeof error === 'string') fail('NodeError', `${service} request failed: ${error}`);
  const status = toNum(getKey(response, 'status'));
  const body = parseOrText(toTemplateStr(getKey(response, 'body')));
  if (status >= 400) fail('NodeError', `${service} error ${formatNumber(status)}: ${errorMessage(body)}`);
  return body;
}

function parseOrText(text: string): Val {
  try {
    return parseJson(text, 'response body');
  } catch {
    return text;
  }
}

/** The most useful message in an API error body. */
function errorMessage(body: Val): string {
  if (isObj(body)) {
    const error = getKey(body, 'error');
    if (isObj(error)) {
      const message = getKey(error, 'message');
      if (typeof message === 'string') return message;
    }
    for (const key of ['message', 'description', 'error_description']) {
      const message = getKey(body, key);
      if (typeof message === 'string') return message;
    }
    if (typeof error === 'string') return error;
  }
  // Whole characters, so an emoji is never cut in half.
  const chars = Array.from(toStr(body));
  return chars.length > 200 ? `${chars.slice(0, 200).join('')}…` : chars.join('');
}

/** A body as items: lists give one item per entry, objects one item, anything else `{data}`. */
export function asItems(v: Val): Item[] {
  const one = (x: Val): Item => (isObj(x) ? x : { data: x });
  return Array.isArray(v) ? v.map(one) : [one(v)];
}

/** `encodeURIComponent`, named for what it is used for here. */
export function enc(text: string): string {
  return encodeURIComponent(text);
}

const B64_STANDARD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function base64(text: string, alphabet: string, pad: boolean): string {
  const bytes = new TextEncoder().encode(text);
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const n = ((bytes[i] ?? 0) << 16) | ((bytes[i + 1] ?? 0) << 8) | (bytes[i + 2] ?? 0);
    const chars = Math.min(4, Math.ceil(((bytes.length - i) * 8) / 6));
    for (let k = 0; k < chars; k++) out += alphabet.charAt((n >> (18 - 6 * k)) & 63);
    if (pad) out += '='.repeat(4 - chars);
  }
  return out;
}

/** URL-safe base64 of the UTF-8 bytes of [text], without padding (Gmail's `raw`). */
export function base64Url(text: string): string {
  return base64(text, B64_URL, false);
}

/** Standard padded base64 of the UTF-8 bytes of [text] (email header encoding). */
export function base64Standard(text: string): string {
  return base64(text, B64_STANDARD, true);
}
