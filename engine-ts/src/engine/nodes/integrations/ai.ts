/** AI chat: one prompt per item to Claude, OpenAI, Gemini or an OpenAI-compatible server. */

import { fail } from '../../../errors.ts';
import { parseJson } from '../../../json.ts';
import { getKey, isObj, toNum, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, type NodeRun, type NodeSpec } from '../spec.ts';
import { apiRequest, apiResume, credentialParam, enc, perItem } from './api.ts';
import { fileMarker, filePath, mimeFromPath } from '../file_refs.ts';

/** Providers reached over their HTTP API with a stored credential. */
const API_PROVIDERS = ['anthropic', 'openai', 'gemini', 'openaiCompatible'];
/** Claude Code in FlowDroid's Ubuntu, signed in with the person's own account; no credential. */
const CLAUDE_CODE = 'claudeCode';
const PROVIDERS = [...API_PROVIDERS, CLAUDE_CODE];

/** Claude's default model; other providers name their model explicitly. */
export const DEFAULT_CLAUDE_MODEL = 'claude-opus-5-5';
export const ANTHROPIC_VERSION = '2026-10-21';
const JSON_INSTRUCTION = 'Reply with only valid JSON, no other text.';

function provider(run: NodeRun): string {
  const p = paramText(run, 'provider', 0);
  if (!PROVIDERS.includes(p)) fail('NodeError', `unknown AI provider ${p}`);
  return p;
}

function model(run: NodeRun, index: number, p: string): string {
  const m = paramText(run, 'model', index);
  if (m !== '') return m;
  if (p === 'anthropic') return DEFAULT_CLAUDE_MODEL;
  // Claude Code picks its own default model.
  if (p === CLAUDE_CODE) return '';
  return fail('NodeError', 'model is required');
}

function buildChat(run: NodeRun, index: number): Obj {
  const p = provider(run);
  const m = model(run, index, p);
  const prompt = paramText(run, 'prompt', index);
  if (prompt === '') fail('NodeError', 'prompt is empty');
  const wantsJson = getKey(run.params, 'json') === true;
  const system = paramText(run, 'system', index);
  const timeout = toNum(paramValue(run, 'timeout', index));
  const timeoutMs = (timeout >= 1 ? timeout : 1) * 1000;
  const image = filePath(run, 'image', index);
  const request = buildChatRequest(run, p, m, prompt, system, wantsJson, timeoutMs, image);
  // The host puts the image's bytes where the marker is before sending.
  if (image !== '') request['inlineFiles'] = true;
  return request;
}

/** One prompt for Claude Code; the host runs it in Ubuntu and returns the reply. */
function buildCliChat(run: NodeRun, index: number): Obj {
  const prompt = paramText(run, 'prompt', index);
  if (prompt === '') fail('NodeError', 'prompt is empty');
  const wantsJson = getKey(run.params, 'json') === true;
  const system = [paramText(run, 'system', index), wantsJson ? JSON_INSTRUCTION : ''].filter((s) => s !== '').join('\n\n');
  const timeout = toNum(paramValue(run, 'timeout', index));
  const image = filePath(run, 'image', index);
  if (image !== '' && !mimeFromPath(image).startsWith('image/')) fail('NodeError', `${image} is not an image`);
  return { prompt, system, model: paramText(run, 'model', index), image, timeoutMs: (timeout >= 1 ? timeout : 1) * 1000 };
}

function runChat(run: NodeRun): { effect: Obj } {
  if (provider(run) !== CLAUDE_CODE) return perItem(run, (i) => buildChat(run, i));
  const chats = itemsOf(run).map((_, i) => buildCliChat(run, i));
  return { effect: { type: 'cliChat', agent: CLAUDE_CODE, chats } };
}

/** Claude Code's replies, one per chat: `{text, model}` or `{error}`. */
function resumeCliChat(run: NodeRun, result: Obj): Item[][] {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const replies = getKey(result, 'replies');
  if (!Array.isArray(replies)) fail('NodeError', 'Claude Code returned no reply');
  return [replies.flatMap((reply, i) => {
    if (!isObj(reply)) return fail('NodeError', 'Claude Code returned no reply');
    const failed = getKey(reply, 'error');
    if (typeof failed === 'string') fail('NodeError', `Claude Code: ${failed}`);
    const text = getKey(reply, 'text');
    const used = getKey(reply, 'model');
    return withJson(run, { text: typeof text === 'string' ? text : '', provider: CLAUDE_CODE, model: typeof used === 'string' ? used : paramText(run, 'model', i) });
  })];
}

const resumeApi = apiResume('AI', toItem);

function resumeChat(run: NodeRun, result: Obj): Item[][] {
  return provider(run) === CLAUDE_CODE ? resumeCliChat(run, result) : resumeApi(run, result);
}

function buildChatRequest(
  run: NodeRun, p: string, m: string, prompt: string, system: string, wantsJson: boolean, timeoutMs: number, image: string,
): Obj {
  const mime = image === '' ? '' : mimeFromPath(image);
  if (image !== '' && !mime.startsWith('image/')) fail('NodeError', `${image} is not an image`);
  switch (p) {
    case 'anthropic': {
      const fullSystem = [system, wantsJson ? JSON_INSTRUCTION : ''].filter((s) => s !== '').join('\n\n');
      const body: Obj = { model: m, max_tokens: 16000 };
      if (fullSystem !== '') body['system'] = fullSystem;
      body['messages'] = [{
        role: 'user',
        content: image === ''
          ? prompt
          : [
              { type: 'image', source: { type: 'base64', media_type: mime, data: fileMarker(image) } },
              { type: 'text', text: prompt },
            ],
      }];
      // A safety decline re-runs on a fallback model inside the same call.
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
        timeoutMs,
      });
    }
    case 'gemini': {
      const parts: Val[] = image === ''
        ? [{ text: prompt }]
        : [{ inline_data: { mime_type: mime, data: fileMarker(image) } }, { text: prompt }];
      const body: Obj = { contents: [{ role: 'user', parts }] };
      if (system !== '') body['systemInstruction'] = { parts: [{ text: system }] };
      if (wantsJson) body['generationConfig'] = { responseMimeType: 'application/json' };
      return apiRequest(run, {
        method: 'POST',
        url: `https://generativelanguage.googleapis.com/v1beta/models/${enc(m)}:generateContent`,
        headers: { 'x-goog-api-key': '{cred:apiKey}' },
        body,
        timeoutMs,
      });
    }
    default: {
      const messages: Val[] = [];
      if (system !== '') messages.push({ role: 'system', content: system });
      messages.push({
        role: 'user',
        content: image === ''
          ? prompt
          : [
              { type: 'text', text: prompt },
              { type: 'image_url', image_url: { url: `data:${mime};base64,${fileMarker(image)}` } },
            ],
      });
      const body: Obj = { model: m, messages };
      if (wantsJson) body['response_format'] = { type: 'json_object' };
      return apiRequest(run, {
        method: 'POST',
        url: '{cred:baseUrl|https://api.openai.com/v1}/chat/completions',
        headers: { Authorization: 'Bearer {cred:apiKey}' },
        body,
        timeoutMs,
      });
    }
  }
}

function at(v: Val, ...path: (string | number)[]): Val {
  let cur = v;
  for (const key of path) {
    if (typeof key === 'number') cur = Array.isArray(cur) ? (cur[key] ?? null) : null;
    else cur = isObj(cur) ? getKey(cur, key) : null;
  }
  return cur;
}

/** The text of every text part (parts with `type: "text"`, or no type at all), joined. */
function texts(parts: Val): string {
  if (!Array.isArray(parts)) return '';
  let out = '';
  for (const p of parts) {
    if (!isObj(p) || (Object.hasOwn(p, 'type') && getKey(p, 'type') !== 'text')) continue;
    const text = getKey(p, 'text');
    if (typeof text === 'string') out += text;
  }
  return out;
}

function replyText(p: string, body: Val): string {
  switch (p) {
    case 'anthropic': {
      if (at(body, 'stop_reason') === 'refusal') {
        const category = at(body, 'stop_details', 'category');
        fail('NodeError', `Claude declined this request${typeof category === 'string' ? ` (${category})` : ''}`);
      }
      return texts(at(body, 'content'));
    }
    case 'gemini':
      return texts(at(body, 'candidates', 0, 'content', 'parts'));
    default: {
      const content = at(body, 'choices', 0, 'message', 'content');
      return typeof content === 'string' ? content : '';
    }
  }
}

function toItem(body: Val, index: number, run: NodeRun): Item[] {
  const p = provider(run);
  const text = replyText(p, body);
  return withJson(run, { text, provider: p, model: model(run, index, p) });
}

/** [item], with its text parsed into `json` when the node asks for a JSON reply. */
function withJson(run: NodeRun, item: Item): Item[] {
  if (getKey(run.params, 'json') === true) {
    try {
      item['json'] = parseJson(item['text'] as string, 'reply');
    } catch {
      fail('NodeError', 'the reply is not valid JSON');
    }
  }
  return [item];
}

export const aiNodes: NodeSpec[] = [
  {
    type: 'ai.chat',
    label: 'AI Chat',
    group: 'ai',
    description: 'Sends a prompt per item to an AI model and outputs its reply.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'provider', label: 'Provider', kind: 'select', default: 'anthropic', options: PROVIDERS },
      credentialParam(API_PROVIDERS),
      { key: 'model', label: 'Model', kind: 'text', default: '', hint: `empty = ${DEFAULT_CLAUDE_MODEL} for Claude, Claude Code's own default for Claude Code` },
      { key: 'system', label: 'Instructions', kind: 'text', default: '' },
      { key: 'prompt', label: 'Prompt', kind: 'text', default: '{{ $json.text }}' },
      { key: 'image', label: 'Image', kind: 'text', default: '', hint: 'a photo for the AI to look at, e.g. {{ $json.file.path }}' },
      { key: 'json', label: 'Reply as JSON', kind: 'boolean', default: false },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: 120 },
    ],
    run: runChat,
    resume: resumeChat,
  },
];
