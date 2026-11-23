import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { resumeExecution, startExecution } from '../src/api.ts';
import { workflow } from './fixtures.ts';

const NOW = Date.UTC(2026, 10, 22, 9);

type State = {
  status: string;
  error: string | null;
  pending: { effect: Record<string, unknown> } | null;
  last: Record<string, Record<string, unknown>[]>;
};

/** A workflow of a manual trigger followed by one node of [type]. */
const single = (type: string, params: object): string =>
  workflow(
    [{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'n', name: 'Step', type, params }],
    [{ from: 'start', to: 'n' }],
  );

const start = (wf: string, items: unknown[] = [{}]): [string, State] => {
  const json = startExecution(wf, 'start', JSON.stringify(items), NOW);
  return [json, JSON.parse(json) as State];
};

const resume = (wf: string, state: string, result: unknown): State =>
  JSON.parse(resumeExecution(wf, state, JSON.stringify(result), NOW + 1)) as State;

const request = (s: State): Record<string, unknown> =>
  (s.pending?.effect['requests'] as Record<string, unknown>[])[0]!;

const ok = (body: unknown, status = 200) => ({ responses: [{ status, headers: {}, body: JSON.stringify(body) }] });

describe('AI chat', () => {
  it('calls Claude with the current API version, a credential reference and server-side fallbacks', () => {
    const wf = single('ai.chat', { credential: 'My Claude', system: 'Be brief.', prompt: 'Hi {{ $json.name }}' });
    const [json, s] = start(wf, [{ name: 'Ann' }]);
    const r = request(s);
    assert.equal(r['url'], 'https://api.anthropic.com/v1/messages');
    assert.equal(r['credential'], 'My Claude');
    assert.deepEqual(r['headers'], {
      'x-api-key': '{cred:apiKey}',
      'anthropic-version': '2026-10-21',
      'anthropic-beta': 'server-side-fallback-2026-07-01',
      'Content-Type': 'application/json',
    });
    assert.deepEqual(JSON.parse(r['body'] as string), {
      model: 'claude-opus-5-5',
      max_tokens: 16000,
      system: 'Be brief.',
      messages: [{ role: 'user', content: 'Hi Ann' }],
      fallbacks: 'default',
    });
    const done = resume(wf, json, ok({ content: [{ type: 'text', text: 'Hello Ann' }], stop_reason: 'end_turn' }));
    assert.deepEqual(done.last['Step'], [{ text: 'Hello Ann', provider: 'anthropic', model: 'claude-opus-5-5' }]);
  });

  it('reports a refusal and API errors clearly', () => {
    const wf = single('ai.chat', { credential: 'c', prompt: 'x' });
    const [json] = start(wf);
    assert.equal(
      resume(wf, json, ok({ stop_reason: 'refusal', stop_details: { category: 'cyber' }, content: [] })).error,
      'Step: NodeError: Claude declined this request (cyber)',
    );
    assert.equal(
      resume(wf, json, ok({ error: { message: 'invalid x-api-key' } }, 401)).error,
      'Step: NodeError: AI error 401: invalid x-api-key',
    );
  });

  it('speaks OpenAI and Gemini, and can parse a JSON reply', () => {
    const openai = single('ai.chat', { provider: 'openai', credential: 'o', model: 'gpt-x', prompt: 'p', json: true });
    const [json, s] = start(openai);
    assert.equal(request(s)['url'], '{cred:baseUrl|https://api.openai.com/v1}/chat/completions');
    const done = resume(openai, json, ok({ choices: [{ message: { content: '{"a":1}' } }] }));
    assert.deepEqual(done.last['Step'], [{ text: '{"a":1}', provider: 'openai', model: 'gpt-x', json: { a: 1 } }]);
    const gemini = single('ai.chat', { provider: 'gemini', credential: 'g', model: 'gemini-x', prompt: 'p' });
    assert.equal(
      request(start(gemini)[1])['url'],
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent',
    );
    assert.equal(start(single('ai.chat', { provider: 'openai', credential: 'o', prompt: 'p' }))[1].error, 'Step: NodeError: model is required');
  });

  it('asks the host to run Claude Code in Ubuntu, with no credential', () => {
    const wf = single('ai.chat', { provider: 'claudeCode', system: 'Be brief.', prompt: 'Hi {{ $json.name }}', json: true, timeout: 300 });
    const [json, s] = start(wf, [{ name: 'Ann' }]);
    assert.equal(s.error, null);
    assert.deepEqual(s.pending?.effect, {
      type: 'cliChat',
      agent: 'claudeCode',
      chats: [{ prompt: 'Hi Ann', system: 'Be brief.\n\nReply with only valid JSON, no other text.', model: '', image: '', timeoutMs: 300000 }],
    });
    const done = resume(wf, json, { replies: [{ text: '{"hi":1}', model: 'claude-opus-5-5' }] });
    assert.deepEqual(done.last['Step'], [{ text: '{"hi":1}', provider: 'claudeCode', model: 'claude-opus-5-5', json: { hi: 1 } }]);
    assert.equal(resume(wf, json, { replies: [{ error: 'not signed in' }] }).error, 'Step: NodeError: Claude Code: not signed in');
    assert.equal(resume(wf, json, { error: 'install Ubuntu first' }).error, 'Step: NodeError: install Ubuntu first');
  });
});

describe('messaging', () => {
  it('sends Telegram messages and surfaces Telegram errors', () => {
    const wf = single('telegram.send', { credential: 'bot', chatId: '42', text: 'hi', parseMode: 'HTML' });
    const [json, s] = start(wf);
    assert.equal(request(s)['url'], 'https://api.telegram.org/bot{cred:botToken}/sendMessage');
    assert.deepEqual(JSON.parse(request(s)['body'] as string), { chat_id: '42', text: 'hi', parse_mode: 'HTML' });
    assert.deepEqual(resume(wf, json, ok({ ok: true, result: { message_id: 7 } })).last['Step'], [{ message_id: 7 }]);
    assert.equal(resume(wf, json, ok({ ok: false, description: 'chat not found' })).error, 'Step: NodeError: Telegram: chat not found');
  });

  it('posts to Discord by webhook or bot', () => {
    const hook = single('discord.send', { credential: 'w', content: 'yo', username: 'FlowDroid' });
    assert.equal(request(start(hook)[1])['url'], '{cred:url}?wait=true');
    const bot = single('discord.send', { mode: 'bot', credential: 'b', channelId: '9', content: 'yo' });
    assert.deepEqual(request(start(bot)[1])['headers'], { Authorization: 'Bot {cred:botToken}', 'Content-Type': 'application/json' });
    assert.equal(start(single('discord.send', { mode: 'bot', credential: 'b', content: 'x' }))[1].error, 'Step: NodeError: channel ID is required');
  });

  it('requires a credential', () => {
    assert.equal(start(single('telegram.send', { chatId: '1', text: 'x' }))[1].error, 'Step: NodeError: choose a credential');
  });
});

describe('databases', () => {
  it('builds Supabase queries and refuses unfiltered updates', () => {
    const select = single('db.supabase', { credential: 's', table: 'tasks', filters: [{ name: 'done', value: 'false' }], limit: 5 });
    const [json, s] = start(select);
    assert.equal(request(s)['url'], '{cred:url}/rest/v1/tasks?select=*&done=eq.false&limit=5');
    assert.deepEqual(resume(select, json, ok([{ id: 1 }, { id: 2 }])).last['Step'], [{ id: 1 }, { id: 2 }]);
    const update = single('db.supabase', { credential: 's', operation: 'update', table: 'tasks', row: { done: true } });
    assert.equal(start(update)[1].error, 'Step: NodeError: add at least one filter before updating rows');
  });

  it('maps Airtable records and Notion pages to items', () => {
    const at = single('db.airtable', { credential: 'a', baseId: 'app1', table: 'Leads', limit: 2 });
    const [json, s] = start(at);
    assert.equal(request(s)['url'], 'https://api.airtable.com/v0/app1/Leads?maxRecords=2');
    const records = { records: [{ id: 'rec1', createdTime: 't', fields: { Name: 'Ann' } }] };
    assert.deepEqual(resume(at, json, ok(records)).last['Step'], [{ id: 'rec1', createdTime: 't', Name: 'Ann' }]);
    const notion = single('db.notion', { credential: 'n', databaseId: 'db1' });
    const [nj] = start(notion);
    const pages = { results: [{ id: 'p1', url: 'u', properties: { Name: {} } }] };
    assert.deepEqual(resume(notion, nj, ok(pages)).last['Step'], [{ id: 'p1', url: 'u', properties: { Name: {} } }]);
  });

  it('asks the phone table store and returns its rows', () => {
    const wf = single('db.table', { operation: 'find', table: 'notes', filters: [{ name: 'tag', value: '{{ $json.t }}' }] });
    const [json, s] = start(wf, [{ t: 'x' }]);
    assert.deepEqual(s.pending?.effect, { type: 'table', table: 'notes', operation: 'find', requests: [{ where: { tag: 'x' }, row: null, limit: 100 }] });
    assert.deepEqual(resume(wf, json, { rows: [{ tag: 'x', n: 1 }] }).last['Step'], [{ tag: 'x', n: 1 }]);
  });
});

describe('Google', () => {
  it('reads sheet rows by header and appends one row per item', () => {
    const read = single('google.sheets', { credential: 'g', spreadsheetId: 'S1', range: 'Sheet1!A1:C9' });
    const [json, s] = start(read);
    assert.equal(request(s)['url'], 'https://sheets.googleapis.com/v4/spreadsheets/S1/values/Sheet1!A1%3AC9');
    const values = { values: [['name', 'age'], ['Ann', '30'], ['Bo']] };
    assert.deepEqual(resume(read, json, ok(values)).last['Step'], [{ name: 'Ann', age: '30' }, { name: 'Bo', age: null }]);
    const append = single('google.sheets', { credential: 'g', operation: 'append', spreadsheetId: 'S1', range: 'Sheet1' });
    const body = JSON.parse(request(start(append, [{ a: 1, b: 'x' }, { a: 2, b: 'y' }])[1])['body'] as string);
    assert.deepEqual(body, { values: [[1, 'x'], [2, 'y']] });
  });

  it('sends Gmail as a base64url RFC 822 message', () => {
    const wf = single('google.gmail', { credential: 'g', to: 'a@b.c', subject: 'Héllo', body: 'Hi' });
    const raw = JSON.parse(request(start(wf)[1])['body'] as string).raw as string;
    const decoded = Buffer.from(raw, 'base64url').toString('utf8');
    assert.equal(decoded, 'To: a@b.c\r\nSubject: =?UTF-8?B?SMOpbGxv?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n\r\nHi');
  });

  it('creates calendar events', () => {
    const wf = single('google.calendar', { credential: 'g', summary: 'Standup', start: '2026-11-23T09:00:00Z', end: '2026-11-23T09:15:00Z' });
    assert.equal(request(start(wf)[1])['url'], 'https://www.googleapis.com/calendar/v3/calendars/primary/events');
  });
});

describe('Execute Command', () => {
  it('asks the host to run the command and reports the exit code', () => {
    const wf = single('system.command', { target: 'ubuntu', command: 'uname -a' });
    const [json, s] = start(wf);
    assert.deepEqual(s.pending?.effect, { type: 'command', commands: [{ target: 'ubuntu', command: 'uname -a', workdir: '', timeoutMs: 60000 }] });
    const okRun = resume(wf, json, { results: [{ exitCode: 0, stdout: 'Linux\n', stderr: '' }] });
    assert.deepEqual(okRun.last['Step'], [{ exitCode: 0, stdout: 'Linux\n', stderr: '' }]);
    const bad = resume(wf, json, { results: [{ exitCode: 2, stdout: '', stderr: 'no such file\n' }] });
    assert.equal(bad.error, 'Step: NodeError: command exited with code 2: no such file');
  });
});

describe('Knowledge base (RAG)', () => {
  const manual = { id: 'start', name: 'Start', type: 'trigger.manual' };
  const one = (type: string, params: object) =>
    workflow([manual, { id: 'k', name: 'KB', type, params }], [{ from: 'start', to: 'k' }]);
  const NOW2 = Date.UTC(2026, 10, 22, 9);
  const begin = (wf: string, items: unknown[]) => {
    const json = startExecution(wf, 'start', JSON.stringify(items), NOW2);
    return [json, JSON.parse(json)] as const;
  };
  const cont = (wf: string, state: string, result: unknown) =>
    JSON.parse(resumeExecution(wf, state, JSON.stringify(result), NOW2 + 1));

  it('adds documents with offline word search by default', () => {
    const wf = one('rag.add', { collection: 'notes', text: '{{ $json.body }}', source: '{{ $json.title }}' });
    const [json, s] = begin(wf, [{ title: 'Wifi', body: 'The password is on the router.' }]);
    assert.deepEqual(s.pending.effect, {
      type: 'knowledge', op: 'add', collection: 'notes', embedder: 'local', chunkSize: 800, overlap: 100,
      documents: [{ text: 'The password is on the router.', source: 'Wifi', metadata: { title: 'Wifi', body: 'The password is on the router.' } }],
    });
    const done = cont(wf, json, { added: [{ source: 'Wifi', chunks: 1 }] });
    assert.deepEqual(done.last['KB'], [{ title: 'Wifi', body: 'The password is on the router.', knowledge: { source: 'Wifi', chunks: 1 } }]);
  });

  it('embeddings need a credential; sizes are kept sensible', () => {
    const [, bad] = begin(one('rag.add', { collection: 'n', embedder: 'openai' }), [{}]);
    assert.equal(bad.error, 'KB: NodeError: choose a credential for the embeddings');
    const [, s] = begin(one('rag.add', { collection: 'n', embedder: 'openai', credential: 'oa', model: 'text-embedding-3-large', chunkSize: 50, overlap: 999 }), [{ text: 'x' }]);
    assert.equal(s.pending.effect.credential, 'oa');
    assert.equal(s.pending.effect.model, 'text-embedding-3-large');
    assert.equal(s.pending.effect.chunkSize, 100);
    assert.equal(s.pending.effect.overlap, 50);
  });

  it('searches per item and attaches matches and context', () => {
    const wf = one('rag.search', { collection: 'notes', query: '{{ $json.q }}', topK: 2 });
    const [json, s] = begin(wf, [{ q: 'wifi password?' }]);
    assert.deepEqual(s.pending.effect, {
      type: 'knowledge', op: 'search', collection: 'notes', queries: [{ query: 'wifi password?', topK: 2, minScore: 0 }],
    });
    const done = cont(wf, json, { results: [{ matches: [{ text: 'On the router', score: 0.9, source: 'Wifi' }], context: 'On the router' }] });
    assert.equal(done.last['KB'][0].knowledge.context, 'On the router');
  });

  it('odd numbers fall back to sensible values', () => {
    const [, a] = begin(one('rag.add', { collection: 'n', chunkSize: -5, overlap: 'lots' }), [{ text: 'x' }]);
    assert.equal(a.pending.effect.chunkSize, 800);
    assert.equal(a.pending.effect.overlap, 0);
    const [, s] = begin(one('rag.search', { collection: 'n', topK: 'many', minScore: 'high' }), [{ text: 'q' }]);
    assert.deepEqual(s.pending.effect.queries, [{ query: 'q', topK: 4, minScore: 0 }]);
    const [, b] = begin(one('rag.search', { collection: 'n', topK: 2.5, minScore: 7 }), [{ text: 'q' }]);
    assert.deepEqual(b.pending.effect.queries, [{ query: 'q', topK: 3, minScore: 1 }]);
  });

  it('lists and deletes', () => {
    const [, list] = begin(one('rag.info', { operation: 'collections' }), [{}]);
    assert.deepEqual(list.pending.effect, { type: 'knowledge', op: 'collections' });
    const [, del] = begin(one('rag.info', { operation: 'deleteSource', collection: 'notes', source: 'Wifi' }), [{}]);
    assert.deepEqual(del.pending.effect, { type: 'knowledge', op: 'deleteSource', collection: 'notes', source: 'Wifi' });
    const [json, s] = begin(one('rag.info', { operation: 'sources', collection: 'notes' }), [{}]);
    assert.equal(s.pending.effect.op, 'sources');
    const done = cont(one('rag.info', { operation: 'sources', collection: 'notes' }), json, { rows: [{ source: 'Wifi', chunks: 1 }] });
    assert.deepEqual(done.last['KB'], [{ source: 'Wifi', chunks: 1 }]);
    const [, empty] = begin(one('rag.search', { collection: '' }), [{}]);
    assert.equal(empty.error, 'KB: NodeError: knowledge base name is required');
  });
});
