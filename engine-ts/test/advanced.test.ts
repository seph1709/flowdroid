import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { nodeCatalog, resumeExecution, startExecution } from '../src/api.ts';
import { workflow } from './fixtures.ts';

const NOW = Date.UTC(2026, 10, 22, 9);

type State = {
  status: string;
  error: string | null;
  pending: { effect: Record<string, unknown>; attempt: number; retry: boolean } | null;
  last: Record<string, Record<string, unknown>[]>;
  memory: Record<string, unknown>;
  runs: { name: string }[];
};

const manual = { id: 'start', name: 'Start', type: 'trigger.manual' };

const single = (type: string, params: object, extra: object = {}): string =>
  workflow([manual, { id: 'n', name: 'Step', type, params, ...extra }], [{ from: 'start', to: 'n' }]);

const start = (wf: string, items: unknown[] = [{}]): [string, State] => {
  const json = startExecution(wf, 'start', JSON.stringify(items), NOW);
  return [json, JSON.parse(json) as State];
};

const resume = (wf: string, state: string, result: unknown): [string, State] => {
  const json = resumeExecution(wf, state, JSON.stringify(result), NOW + 1);
  return [json, JSON.parse(json) as State];
};

const ok = (body: unknown, status = 200) => ({ responses: [{ status, headers: {}, body: JSON.stringify(body) }] });

describe('Loop Over Items', () => {
  const loopWf = (batchSize: number) =>
    workflow(
      [
        manual,
        { id: 'loop', name: 'Loop', type: 'core.loop', params: { batchSize } },
        { id: 'tag', name: 'Tag', type: 'core.set', params: { fields: [{ name: 'seen', value: '{{ $json.n * 10 }}' }] } },
        { id: 'end', name: 'End', type: 'core.noop' },
      ],
      [
        { from: 'start', to: 'loop' },
        { from: 'loop', output: 1, to: 'tag' },
        { from: 'tag', to: 'loop' },
        { from: 'loop', output: 0, to: 'end' },
      ],
    );

  it('sends batches round the loop, then everything out of done', () => {
    const [, s] = start(loopWf(2), [{ n: 1 }, { n: 2 }, { n: 3 }]);
    assert.equal(s.status, 'success');
    assert.deepEqual(
      s.last['End']!.map((i) => i['seen']),
      [10, 20, 30],
    );
    assert.equal(s.runs.filter((r) => r.name === 'Tag').length, 2);
    assert.deepEqual(s.memory, {});
  });

  it('treats a batch size below one as one', () => {
    const [, s] = start(loopWf(0), [{ n: 1 }, { n: 2 }]);
    assert.equal(s.runs.filter((r) => r.name === 'Tag').length, 2);
  });
});

describe('pinned data and retries', () => {
  it('uses pinned output only when the run asks for it', () => {
    const nodes = [
      manual,
      { id: 'h', name: 'Fetch', type: 'http.request', params: { url: 'https://x.test' }, pinned: [{ cached: true }] },
    ];
    const conns = [{ from: 'start', to: 'h' }];
    const [, live] = start(workflow(nodes, conns));
    assert.equal(live.status, 'waiting');
    const [, pinned] = start(workflow(nodes, conns, {}, { usePinnedData: true }));
    assert.equal(pinned.status, 'success');
    assert.deepEqual(pinned.last['Fetch'], [{ cached: true }]);
  });

  it('pinned trigger output replaces the trigger items', () => {
    const wf = workflow([{ ...manual, pinned: [{ a: 1 }] }], [], {}, { usePinnedData: true });
    const [, s] = start(wf, [{ b: 2 }]);
    assert.deepEqual(s.last['Start'], [{ a: 1 }]);
  });

  it('waits and runs a failed effect node again, up to its tries', () => {
    const wf = single('http.request', { url: 'https://x.test' }, { retryOnFail: true, maxTries: 2, waitBetweenTries: 500 });
    let [json, s] = start(wf);
    assert.equal(s.pending!.attempt, 1);
    [json, s] = resume(wf, json, { responses: [{ error: 'offline' }] });
    assert.equal(s.status, 'waiting');
    assert.deepEqual(s.pending!.effect, { type: 'wait', ms: 500, reason: 'retry 2 of 2: NodeError: request failed: offline' });
    assert.equal(s.pending!.retry, true);
    [json, s] = resume(wf, json, {});
    assert.equal(s.pending!.effect['type'], 'http');
    assert.equal(s.pending!.attempt, 2);
    [json, s] = resume(wf, json, { responses: [{ error: 'offline' }] });
    assert.equal(s.status, 'error');
    assert.equal(s.error, 'Step: NodeError: request failed: offline');
  });

  it('succeeds on a later try', () => {
    const wf = single('http.request', { url: 'https://x.test' }, { retryOnFail: true });
    let [json] = start(wf);
    [json] = resume(wf, json, { responses: [{ status: 503, headers: {}, body: '' }] });
    [json] = resume(wf, json, {});
    const [, s] = resume(wf, json, { responses: [{ status: 200, headers: {}, body: '{"ok":1}' }] });
    assert.equal(s.status, 'success');
    assert.deepEqual(s.last['Step'], [{ ok: 1 }]);
  });
});

describe('Code', () => {
  it('sends the code and items to the host and turns what it returned into items', () => {
    const wf = single('core.code', { language: 'python', code: 'return [{"x": 1}, 2]' });
    const [json, s] = start(wf, [{ a: 1 }]);
    assert.deepEqual(s.pending!.effect, {
      type: 'code',
      language: 'python',
      mode: 'allItems',
      code: 'return [{"x": 1}, 2]',
      items: [{ a: 1 }],
      timeoutMs: 60000,
    });
    const [, done] = resume(wf, json, { results: [{ x: 1 }, 2] });
    assert.deepEqual(done.last['Step'], [{ x: 1 }, { value: 2 }]);
  });

  it('runs once per item and keeps template braces as code', () => {
    const wf = single('core.code', { mode: 'eachItem', code: 'return {{ item }}' });
    const [json, s] = start(wf, [{ a: 1 }, { a: 2 }]);
    assert.equal(s.pending!.effect['code'], 'return {{ item }}');
    const [, done] = resume(wf, json, { results: [{ b: 1 }, null] });
    assert.deepEqual(done.last['Step'], [{ b: 1 }]);
    const [, bad] = resume(wf, json, { results: [1] });
    assert.equal(bad.error, 'Step: NodeError: expected 2 code results');
    const [, failed] = resume(wf, json, { error: 'SyntaxError: x' });
    assert.equal(failed.error, 'Step: NodeError: SyntaxError: x');
  });

  it('rejects empty code and unknown languages', () => {
    assert.equal(start(single('core.code', { code: '  ' }))[1].error, 'Step: NodeError: code is empty');
    assert.equal(start(single('core.code', { language: 'ruby' }))[1].error, 'Step: NodeError: unknown language ruby');
  });
});

describe('Execute Workflow', () => {
  it('calls another workflow with all items or one item at a time', () => {
    const wf = single('core.executeWorkflow', { workflowId: 'wf_child', mode: 'eachItem' });
    const [json, s] = start(wf, [{ a: 1 }, { a: 2 }]);
    assert.deepEqual(s.pending!.effect, { type: 'workflow', workflowId: 'wf_child', wait: true, runs: [[{ a: 1 }], [{ a: 2 }]] });
    const [, done] = resume(wf, json, { outputs: [[{ r: 1 }], [{ r: 2 }, { r: 3 }]] });
    assert.deepEqual(done.last['Step'], [{ r: 1 }, { r: 2 }, { r: 3 }]);
  });

  it('passes items on without waiting, and needs a workflow', () => {
    const wf = single('core.executeWorkflow', { workflowId: 'w', wait: false });
    const [json] = start(wf, [{ a: 1 }]);
    assert.deepEqual(resume(wf, json, {})[1].last['Step'], [{ a: 1 }]);
    assert.equal(start(single('core.executeWorkflow', {}))[1].error, 'Step: NodeError: choose a workflow');
  });
});

describe('AI Agent', () => {
  const tools = [
    { kind: 'http', name: 'weather', description: '', config: 'https://wttr.in/' },
    { kind: 'command', name: 'shell', description: 'Run Linux commands', config: 'ubuntu' },
  ];

  it('loops between Claude and the tools until Claude answers', () => {
    const wf = single('ai.agent', { credential: 'c', prompt: 'Weather in {{ $json.city }}?', tools, webSearch: true });
    let [json, s] = start(wf, [{ city: 'Oslo' }]);
    const req = (s.pending!.effect['requests'] as Record<string, unknown>[])[0]!;
    const body = JSON.parse(req['body'] as string);
    assert.equal(req['credential'], 'c');
    assert.deepEqual(body.messages, [{ role: 'user', content: 'Weather in Oslo?' }]);
    assert.deepEqual(body.thinking, { type: 'adaptive' });
    assert.deepEqual(body.tools.map((t: { name: string }) => t.name), ['weather', 'shell', 'web_search']);
    assert.equal(body.tools[0].description, 'Calls a web API and returns the response.');
    assert.deepEqual(body.tools[0].input_schema.required, ['url']);

    const use = { type: 'tool_use', id: 'tu_1', name: 'weather', input: { url: 'https://wttr.in/Oslo' } };
    [json, s] = resume(wf, json, ok({ content: [{ type: 'text', text: 'Checking.' }, use], stop_reason: 'tool_use' }));
    const toolEffect: unknown = s.pending!.effect;
    assert.deepEqual(toolEffect, {
      type: 'tools',
      calls: [{ id: 'tu_1', kind: 'http', name: 'weather', config: 'https://wttr.in/', input: { url: 'https://wttr.in/Oslo' } }],
    });

    [json, s] = resume(wf, json, { results: [{ content: 'Sunny, 12°C', isError: false }] });
    const again = JSON.parse((s.pending!.effect['requests'] as Record<string, unknown>[])[0]!['body'] as string);
    assert.deepEqual(again.messages.slice(1), [
      { role: 'assistant', content: [{ type: 'text', text: 'Checking.' }, use] },
      { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: 'Sunny, 12°C' }] },
    ]);

    const [, done] = resume(wf, json, ok({ content: [{ type: 'text', text: 'Sunny in Oslo.' }], stop_reason: 'end_turn' }));
    assert.equal(done.status, 'success');
    assert.deepEqual(done.last['Step'], [{ text: 'Sunny in Oslo.', steps: 2, stopReason: 'end_turn' }]);
  });

  it('works through items one after another and stops at the step limit', () => {
    const wf = single('ai.agent', { credential: 'c', prompt: '{{ $json.q }}', tools, maxSteps: 1 });
    let [json, s] = start(wf, [{ q: 'a' }, { q: 'b' }]);
    [json, s] = resume(wf, json, ok({ content: [{ type: 'text', text: 'A' }], stop_reason: 'end_turn' }));
    const next = JSON.parse((s.pending!.effect['requests'] as Record<string, unknown>[])[0]!['body'] as string);
    assert.deepEqual(next.messages, [{ role: 'user', content: 'b' }]);
    const use = { type: 'tool_use', id: 't', name: 'shell', input: { command: 'ls' } };
    [json, s] = resume(wf, json, ok({ content: [use], stop_reason: 'tool_use' }));
    const [, stopped] = resume(wf, json, { results: [{ content: 'x', isError: true }] });
    assert.equal(stopped.error, 'Step: NodeError: stopped after 1 steps without a final answer');
  });

  it('reports refusals, bad tool names and tool errors', () => {
    const wf = single('ai.agent', { credential: 'c', prompt: 'x' });
    const [json] = start(wf);
    assert.equal(resume(wf, json, ok({ content: [], stop_reason: 'refusal' }))[1].error, 'Step: NodeError: Claude declined this request');
    assert.equal(
      resume(wf, json, ok({ error: { message: 'bad key' } }, 401))[1].error,
      'Step: NodeError: Claude error 401: bad key',
    );
    const bad = single('ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'http', name: 'no spaces', config: '' }] });
    assert.equal(start(bad)[1].error, 'Step: NodeError: tool name "no spaces" must be 1–64 letters, digits, _ or -');
  });
});

describe('device, mail, feeds and files', () => {
  it('sends SMS per item', () => {
    const [, s] = start(single('android.sms', { to: '{{ $json.n }}', text: 'hi' }), [{ n: '+100' }]);
    assert.deepEqual(s.pending!.effect, { type: 'sms', messages: [{ to: '+100', text: 'hi' }] });
    assert.equal(start(single('android.sms', {}))[1].error, 'Step: NodeError: phone number is required');
  });

  it('sends email through the named credential', () => {
    const [, s] = start(single('email.send', { credential: 'Mail', to: 'a@b.c', subject: 'S', text: 'T' }));
    assert.deepEqual(s.pending!.effect, {
      type: 'email',
      credential: 'Mail',
      messages: [{ to: 'a@b.c', subject: 'S', text: 'T', html: false }],
    });
  });

  it('reads feeds and files, one result per item', () => {
    const rss = single('rss.read', { url: 'https://f.test/{{ $json.f }}' });
    const [json, s] = start(rss, [{ f: 'a' }, { f: 'b' }]);
    assert.deepEqual(s.pending!.effect, { type: 'rss', urls: ['https://f.test/a', 'https://f.test/b'] });
    assert.deepEqual(resume(rss, json, { feeds: [[{ title: '1' }], [{ title: '2' }, 'x']] })[1].last['Step'], [
      { title: '1' },
      { title: '2' },
    ]);
    const files = single('files', { operation: 'append', path: 'log.txt', content: 'line' });
    const [fjson, f] = start(files);
    assert.deepEqual(f.pending!.effect, { type: 'file', requests: [{ operation: 'append', path: 'log.txt', content: 'line' }] });
    assert.deepEqual(resume(files, fjson, { results: [{ path: 'log.txt', size: 4 }] })[1].last['Step'], [{ path: 'log.txt', size: 4 }]);
    assert.equal(start(single('files', { operation: 'read', path: '' }))[1].error, 'Step: NodeError: path is required');
  });

  it('lets HTTP Request authenticate with a credential', () => {
    const [, s] = start(single('http.request', { url: 'https://x.test', credential: 'GitHub' }));
    const r = (s.pending!.effect['requests'] as Record<string, unknown>[])[0]!;
    assert.equal(r['credential'], 'GitHub');
    assert.equal(r['auth'], true);
  });

  it('uploads to Google Drive as one multipart request', () => {
    const wf = single('google.drive', { credential: 'G', operation: 'upload', name: 'a.txt', content: 'hello' });
    const [json, s] = start(wf);
    const r = (s.pending!.effect['requests'] as Record<string, unknown>[])[0]!;
    assert.equal(
      r['body'],
      '--flowdroid-part\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{"name":"a.txt"}\r\n' +
        '--flowdroid-part\r\nContent-Type: text/plain\r\n\r\nhello\r\n--flowdroid-part--',
    );
    assert.deepEqual(resume(wf, json, ok({ id: 'f1', name: 'a.txt' }))[1].last['Step'], [{ id: 'f1', name: 'a.txt' }]);
  });
});

describe('catalog', () => {
  it('lists the new triggers and parameter kinds', () => {
    const catalog = JSON.parse(nodeCatalog()) as { type: string; params: { kind: string }[] }[];
    const types = catalog.map((n) => n.type);
    for (const t of ['trigger.sms', 'trigger.notification', 'trigger.phone', 'trigger.place', 'trigger.share', 'trigger.tile', 'trigger.rss', 'trigger.email', 'trigger.subworkflow', 'trigger.error']) {
      assert.ok(types.includes(t), t);
    }
    const kinds = new Set(catalog.flatMap((n) => n.params.map((p) => p.kind)));
    for (const k of ['workflow', 'code', 'tools']) assert.ok(kinds.has(k), k);
  });
});

describe('Speak Text voices', () => {
  it('keeps the plain phone voice as before', () => {
    const [, s] = start(single('android.speak', { text: 'Hi {{ $json.name }}' }), [{ name: 'Ada' }]);
    assert.deepEqual(s.pending?.effect, { type: 'speak', text: 'Hi Ada' });
  });

  it('passes a phone voice and speed', () => {
    const [, s] = start(single('android.speak', { text: 'Hi', voice: 'en-us-x-tpf-local', speed: 1.25 }));
    assert.deepEqual(s.pending?.effect, { type: 'speak', text: 'Hi', voice: 'en-us-x-tpf-local', speed: 1.25 });
  });

  it('asks the host for a cloud voice with its credential and style', () => {
    const [, s] = start(
      single('android.speak', { text: 'Hi', provider: 'openai', credential: 'My OpenAI', voice: 'coral', style: 'warm', speed: 9 }),
    );
    assert.deepEqual(s.pending?.effect, {
      type: 'speak', text: 'Hi', provider: 'openai', credential: 'My OpenAI', voice: 'coral', speed: 4, style: 'warm',
    });
  });

  it('needs a credential for cloud voices', () => {
    const [, s] = start(single('android.speak', { text: 'Hi', provider: 'elevenlabs' }));
    assert.equal(s.error, 'Step: NodeError: choose a credential for the cloud voice');
    const [, t] = start(single('android.speak', { text: 'Hi', provider: 'nope', credential: 'x' }));
    assert.equal(t.error, 'Step: NodeError: unknown voice provider nope');
  });
});
