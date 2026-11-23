/**
 * Writes `cases.jsonl` for `rust-anything record --inputs`: realistic calls
 * to the public API, so the Rust port is checked on real workflows, full
 * effect round-trips and a seeded fuzz of the expression language.
 *
 *   node scripts/gen-cases.ts > ../core/flowcore/inputs.jsonl
 */

import { resumeExecution, startExecution } from '../src/api.ts';
import { fixtures, workflow } from '../test/fixtures.ts';

type Case = { fn: string; args: unknown[] };
const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const cases: Case[] = [];
const add = (fn: string, ...args: unknown[]): void => {
  cases.push({ fn, args });
};

/** mulberry32: small, seeded, reproducible. */
function rng(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = rng(20261121);
const pick = <T>(list: readonly T[]): T => list[Math.floor(rand() * list.length)]!;

// ---------- expressions ----------

const STRINGS = ['', 'a', 'Hello World', 'ß', 'İstanbul', 'ΑΣ', '😀x', '  pad　', '42', ' 7 ', '1e3', '0x10', 'a,b,,c', 'café'];
const NUMBERS = [0, 1, -1, 2.5, -2.5, 0.1, 1e21, 1.5e-7, 123456789.125, 9007199254740993, -0.4];

const CONTEXTS = [
  { $json: { name: 'Ann', age: 30, tags: ['vip', 'new'], nested: { deep: [1, { x: 'y' }] }, nil: null, ok: true } },
  { $json: { s: 'ß😀İ', n: -0, big: 1e21, small: 1e-7, list: [3, 1, 2], empty: '', zero: 0, '10': 'ten', '2': 'two', b: 1 } },
  { $json: {}, $index: 3, $now: '2026-11-21T08:30:00.000Z', $vars: { k: 'v' }, $node: { Prev: { json: { id: 9 }, all: [{ id: 9 }] } } },
];

function literal(): string {
  switch (Math.floor(rand() * 4)) {
    case 0: return String(pick(NUMBERS)).replace('-', '- ');
    case 1: return JSON.stringify(pick(STRINGS));
    case 2: return pick(['true', 'false', 'null', 'undefined']);
    default: return `[${literal()}, ${literal()}]`;
  }
}

function path(): string {
  return pick([
    '$json', '$json.name', '$json.tags', '$json.tags[1]', '$json.nested.deep[1].x', '$json.nil', '$json.age',
    '$json.s', '$json.n', '$json.big', '$json.small', '$json.list', '$json.empty', '$json["10"]', '$json.missing.x',
    '$index', '$now', '$vars.k', '$node["Prev"].json.id', '$json.tags.length', '$json.s.length',
  ]);
}

const METHODS = [
  '.toUpperCase()', '.toLowerCase()', '.trim()', '.includes("a")', '.startsWith("H")', '.endsWith("d")', '.indexOf("l")',
  '.split(",")', '.split("")', '.split()', '.replace("l", "L")', '.replaceAll("l", "L")', '.slice(1)', '.slice(-2, 5)',
  '.join("-")', '.join()', '.first()', '.last()', '.toString()', '.length', '[0]',
];

function expr(depth: number): string {
  if (depth <= 0) return rand() < 0.5 ? literal() : path();
  switch (Math.floor(rand() * 7)) {
    case 0: return `${expr(depth - 1)} ${pick(['+', '-', '*', '/', '%', '==', '!=', '<', '<=', '>', '>=', '&&', '||', '??'])} ${expr(depth - 1)}`;
    case 1: return `${pick(['!', '-'])}${expr(depth - 1)}`;
    case 2: return `(${expr(depth - 1)})${pick(METHODS)}`;
    case 3: return `${expr(depth - 1)} ? ${expr(depth - 1)} : ${expr(depth - 1)}`;
    case 4: return `${pick(['Math.round', 'Math.floor', 'Math.ceil', 'Math.abs', 'Math.min', 'Math.max', 'String', 'Number', 'Boolean', 'JSON.stringify'])}(${expr(depth - 1)})`;
    case 5: return `${path()}${pick(METHODS)}`;
    default: return expr(depth - 1);
  }
}

for (let i = 0; i < 1500; i++) {
  const template = rand() < 0.7 ? `{{ ${expr(3)} }}` : `x {{ ${expr(2)} }} y {{ ${expr(1)} }}`;
  add('evaluateTemplate', template, JSON.stringify(pick(CONTEXTS)));
}

const HANDWRITTEN = [
  '{{ JSON.parse("[1,{\\"a\\":-0}]") }}', '{{ JSON.parse("1e400") }}', '{{ JSON.parse("{\\"a\\":1,\\"a\\":2}") }}',
  '{{ JSON.parse("{\\"b\\":1,\\"2\\":0,\\"1\\":0}") }}', '{{ JSON.parse("nope") }}', '{{ 1e21 + "" }}', '{{ 1.5e-7 + "" }}',
  '{{ 0.000001 + "" }}', '{{ 123e-20 }}', '{{ 2 ** 3 }}', '{{ a = 1 }}', '{{ $json.f() }}', '{{ (1)(2) }}', '{{ [1,2', "{{ 'it\\'s' }}",
  '{{ "\\n\\t\\x" }}', '{{ 1 .toString() }}', '{{ 1.5.toString() }}', '{{ 5 % -3 }}', '{{ -5 % 3 }}', '{{ Math.max() }}', '{{ Math.min() }}',
  '{{ Math.round(0.49999999999999994) }}', '{{ "ß".toUpperCase() }}', '{{ "İ".toLowerCase() }}', '{{ "ΑΣ".toLowerCase() }}',
  '{{ "😀abc".slice(1, 3) }}', '{{ "😀abc".indexOf("a") }}', '{{ "😀".length }}', '{{ "a😀b".split("") }}', '{{ "b" < "ä" }}',
  '{{ "😀" < "￿" }}', '{{ [1, 2] + 3 }}', '{{ null + 1 }}', '{{ "5" * "2" }}', '{{ " 12 " - 1 }}', '{{ ".5" * 2 }}', '{{ "5." * 2 }}',
  '{{ "+5" * 1 }}', '{{ "1_000" * 1 }}', '{{ "Infinity" * 1 }}', '{{ [] == [] }}', '{{ 0 == -0 }}', '{{ {} }}', '{{ $json.n }}',
  '{{ String(-0) }}', '{{ constructor }}', '{{ toString }}', '{{ __proto__ }}', '{{ hasOwnProperty("a") }}', '{{ $json["__proto__"] }}', '{{ $json.constructor }}', '}} {{ 1 }} {{', '{{{ 1 }}}', '{{ 1 }}}}', '{{}}{{ 2 }}',
];
for (const template of HANDWRITTEN) {
  for (const ctx of CONTEXTS) add('evaluateTemplate', template, JSON.stringify(ctx));
}
for (const ctx of ['', '[]', 'null', '{"$json":1}', '{"__proto__":{"a":1}}', '{"x":' + '['.repeat(65) + ']'.repeat(65) + '}']) {
  add('evaluateTemplate', '{{ $json }}', ctx);
}

// ---------- cron ----------

const CRONS = [
  '* * * * *', '*/5 * * * *', '0 */2 * * *', '15 14 1 * *', '0 22 * * 1-5', '23 0-20/2 * * *', '5 4 * * 0', '5 4 * * 7',
  '0 0 1,15 * 3', '0 0 29 2 *', '0 0 30 2 *', '59 23 31 12 *', '0 12 * 6-8 *', ' 0  9  *  *  * ', '0 9 * * 1,3,5', '30/10 * * * *',
  '1-59/58 * * * *', '* * * * * *', '', '61 * * * *', 'a * * * *', '*/x * * * *', '1-2-3 * * * *', '1/2/3 * * * *', '-1 * * * *',
  '* 24 * * *', '* * 32 * *', '* * * 13 *', '* * * * 8', '001 * * * *', '* * * * 7-7',
];
const TIMES = [0, 1.7e12, Date.UTC(2026, 1, 28, 23, 59, 59, 999), Date.UTC(2024, 1, 29), -1, -8.64e15, 8.64e15, 1.5, -62135596800000, Date.UTC(2026, 11, 31, 23, 59)];
const OFFSETS = [0, 480, -300, 345, 1440, -1440];
for (const expression of CRONS) {
  for (let i = 0; i < 6; i++) add('nextCronRun', expression, pick(TIMES), pick(OFFSETS));
}
for (const [after, offset] of [[Number.NaN, 0], [Infinity, 0], [8.64e15 + 1, 0], [0, 1441], [0, 0.5], [0, Number.NaN]]) {
  add('nextCronRun', '* * * * *', after, offset);
}

// ---------- workflows ----------

const NOW = Date.UTC(2026, 10, 21, 8, 30);

/** Records a start call and every resume call of the run, answering effects with `answers` in turn. */
function session(wf: string, trigger: string, items: unknown[], answers: unknown[]): void {
  const itemsJson = JSON.stringify(items);
  add('startExecution', wf, trigger, itemsJson, NOW);
  let state: string;
  try {
    state = startExecution(wf, trigger, itemsJson, NOW);
  } catch {
    return;
  }
  for (const [i, answer] of answers.entries()) {
    if ((JSON.parse(state) as { status: string }).status !== 'waiting') return;
    const result = JSON.stringify(answer);
    add('resumeExecution', wf, state, result, NOW + i + 1);
    try {
      state = resumeExecution(wf, state, result, NOW + i + 1);
    } catch {
      return;
    }
  }
}

const PEOPLE = [[{ name: 'Ann', age: 30 }, { name: 'Bo', age: '12' }], [], [{ name: 'Ünïcødé', age: 18 }], [{ age: 'x' }], [{ name: null, age: [] }]];
for (const items of PEOPLE) session(fixtures.setAndIf, 'start', items, []);

const ORDER_SETS = [
  [{ orders: [{ id: 1, total: 10, tags: ['vip'] }, { id: 2, total: 80, tags: [] }, { id: 2, total: 99 }, { id: 3, total: '60' }, { id: 4, total: null }] }],
  [{ orders: [] }],
  [{ orders: 'nope' }],
  [{ orders: [1, 'two', null, { id: 'x', total: 51 }] }, { orders: [{ id: 'x', total: 52 }] }],
  [{ orders: [{ id: 1, total: Number.MAX_VALUE }, { id: 2, total: -1e-300 }, { id: 3, total: 'abc' }, { id: 4, total: 'abd' }, { id: 5, total: true }] }],
];
for (const items of ORDER_SETS) session(fixtures.dataPipeline, 'start', items, []);

for (const items of [[{ kind: 'a' }, { kind: 'bee' }, { kind: 'z' }], [{ kind: 'a' }], [{ kind: 'b' }], [{ kind: 'q' }, { kind: 'r' }], [{}]]) {
  session(fixtures.switchMerge, 'start', items, []);
}

const HTTP_ANSWERS = [
  [{ responses: [{ status: 200, headers: { 'content-type': 'application/json' }, body: '{"name":"Zed","n":1.5}' }] }, {}, {}],
  [{ responses: [{ status: 200, body: '[{"name":"A"},2,"three"]' }] }, {}, {}, {}, {}],
  [{ responses: [{ status: 500, body: 'boom' }] }],
  [{ responses: [{ error: 'timeout' }] }],
  [{ responses: [] }],
  [{ responses: [{ status: 200, body: 'plain text' }] }, { error: 'notifications blocked' }],
  [[1]],
];
for (const answers of HTTP_ANSWERS) session(fixtures.httpThenNotify, 'hook', [{ body: { id: 7 } }], answers);
session(fixtures.httpThenNotify, 'hook', [{ body: { id: 'a b' } }, { body: {} }], [{ responses: [{ status: 201, body: '{}' }, { status: 204, body: '' }] }, {}, {}]);

const DEVICE_ANSWERS = [
  [{ level: 42, charging: false }, { latitude: 14.5, longitude: 121, accuracy: 9 }, { text: 'copied' }, {}, {}, {}, {}, {}],
  [{ level: 100, charging: true, extra: 1 }, { latitude: -33.9, longitude: 18.4 }, {}, {}, {}, {}, {}, {}],
  [{ error: 'battery unavailable' }],
  [{ level: 'n/a' }, { error: 'permission denied' }],
];
for (const answers of DEVICE_ANSWERS) session(fixtures.deviceNodes, 'start', [{}], answers);

for (const items of [[{ a: 'abc' }], [{ a: null }], [{}, { a: 1 }]]) session(fixtures.failures, 'start', items, []);
session(fixtures.loop, 'start', [{}], []);

// Each node type on its own, with assorted parameters.
const SINGLE_NODES: [string, object][] = [
  ['core.set', { fields: [{ name: 'a.b.c', value: 1 }, { name: 'a.b', value: '{{ $json }}' }, { name: '__proto__', value: 'p' }] }],
  ['core.set', { fields: [{ name: '', value: 1 }] }],
  ['core.set', { fields: 'oops' }],
  ['core.set', { fields: [7] }],
  ['core.limit', { max: '{{ 1 + 1 }}' }],
  ['core.limit', { max: -3 }],
  ['core.limit', { max: 'lots' }],
  ['core.sort', { field: 'v' }],
  ['core.sort', { field: '' }],
  ['core.removeDuplicates', {}],
  ['core.aggregate', {}],
  ['core.aggregate', { field: 'v.w' }],
  ['core.splitOut', { field: 'v' }],
  ['core.if', { conditions: [{ left: '{{ $json.v }}', op: 'isEmpty' }] }],
  ['core.if', { conditions: [{ left: '{{ $json.v }}', op: 'nope' }] }],
  ['core.if', { conditions: ['bad'] }],
  ['core.filter', { conditions: [{ left: '{{ $json.v }}', op: 'lt', right: 'm' }, { left: 1, op: 'isTrue' }] }],
  ['core.filter', { conditions: [{ left: '{{ $json.v }}', op: 'notEquals', right: '{{ 3 }}' }] }],
  ['core.filter', { combine: 'or', conditions: [
    { left: '{{ $json.v }}', op: 'notContains', right: 'b' }, { left: '{{ $json.v }}', op: 'endsWith', right: '3' },
    { left: '{{ $json.v }}', op: 'gte', right: 3 }, { left: '{{ $json.v }}', op: 'lte', right: 'a' },
    { left: '{{ $json.v }}', op: 'isNotEmpty' }, { left: '{{ $json.v }}', op: 'isFalse' }, { left: '{{ $json.v }}' },
  ] }],
  ['core.if', { conditions: [{ left: '{{ $json.v }}', op: 'gt', right: '{{ $json.v }}' }, { left: '{{ $json.v }}', op: 'lt', right: 'z' }] }],
  ['core.switch', { rules: [{ left: '{{ $json.v }}', op: 'contains', right: 1 }] }],
  ['core.merge', { mode: 'chooseBranch', output: 'input2' }],
  ['core.merge', { mode: 'zip' }],
  ['core.wait', { seconds: '{{ -1 }}' }],
  ['core.respond', { body: '{{ $json }}', status: '404', contentType: 'text/plain' }],
  ['http.request', { url: '' }],
  ['http.request', { url: 'https://x.test', method: 'delete', timeout: -1, responseFormat: 'text', fullResponse: true, ignoreHttpErrors: true, headers: [{ name: 'content-type', value: 'text/csv' }], body: '{{ [1,2] }}' }],
  ['android.clipboardRead', { field: 'c.d' }],
  ['android.vibrate', { ms: 'x' }],
  ['trigger.schedule', {}],
  ['some.unknown', {}],
];
const VALUES = [[{ v: 3 }, { v: 1 }, { v: 'b' }, { v: null }, { v: 'a' }, { v: 3 }], [{ v: [1, 2, { k: 1 }] }, { v: [] }], [{ v: { w: 'deep' } }], [{ v: '' }, {}]];
const ANSWERS = [{}, { responses: [{ status: 404, headers: { a: 'b' }, body: 'missing' }] }, { text: 'clip' }, { error: 'denied' }];
for (const [type, params] of SINGLE_NODES) {
  const wf = workflow(
    [{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'n', name: 'Node', type, params }, { id: 'end', name: 'End', type: 'core.noop' }],
    [{ from: 'start', to: 'n' }, { from: 'n', to: 'end' }, { from: 'n', output: 1, to: 'end' }],
  );
  for (const items of VALUES) session(wf, 'start', items, [pick(ANSWERS)]);
  add('validateWorkflow', wf);
}

// Integration nodes: each with assorted parameters and host answers.
const okBody = (body: unknown, status = 200) => ({ responses: [{ status, headers: {}, body: JSON.stringify(body) }] });
const INTEGRATIONS: [string, object, unknown[]][] = [
  ['ai.chat', { credential: 'c', system: 'Be brief.', prompt: 'Hi {{ $json.v }}' }, [
    okBody({ content: [{ type: 'text', text: 'Hello' }, { type: 'tool_use' }, { type: 'text', text: '!' }], stop_reason: 'end_turn' }),
    okBody({ stop_reason: 'refusal', stop_details: { category: 'bio' } }),
    okBody({ stop_reason: 'refusal' }),
    okBody({ error: { message: 'overloaded' } }, 529),
    { responses: [{ error: 'timeout' }] },
  ]],
  ['ai.chat', { provider: 'openai', credential: 'c', model: 'm', prompt: '{{ $json.v }}', json: true }, [
    okBody({ choices: [{ message: { content: '{"x":[1,2]}' } }] }),
    okBody({ choices: [{ message: { content: 'not json' } }] }),
    okBody({ choices: [] }),
  ]],
  ['ai.chat', { provider: 'gemini', credential: 'c', model: 'g/1 x', system: 's', prompt: 'p', json: true }, [
    okBody({ candidates: [{ content: { parts: [{ text: '[1' }, { text: ']' }] } }] }),
  ]],
  ['ai.chat', { provider: 'openaiCompatible', credential: 'c', prompt: 'p' }, [{}]],
  ['ai.chat', { provider: 'mystery', credential: 'c', prompt: 'p' }, [{}]],
  ['ai.chat', { credential: 'c', prompt: '' }, [{}]],
  ['ai.chat', { credential: 'c', prompt: 'x', timeout: 0 }, [okBody({ content: 'odd' })]],
  ['ai.chat', { provider: 'claudeCode', system: 's', prompt: 'Hi {{ $json.v }}', json: true }, [
    { replies: [{ text: '{"a":1}', model: 'm' }] }, { replies: [{ text: 'not json' }] }, { replies: [{ error: 'signed out' }] },
    { replies: [7] }, { replies: 'x' }, { error: 'no Ubuntu' }, {},
  ]],
  ['ai.chat', { provider: 'claudeCode', model: 'sonnet', prompt: 'p', timeout: 0 }, [{ replies: [{ text: 'ok' }] }]],
  ['ai.chat', { provider: 'claudeCode', prompt: '' }, [{}]],
  ['telegram.send', { credential: 'b', chatId: '{{ $json.v }}', text: 'hi', parseMode: 'MarkdownV2' }, [
    okBody({ ok: true, result: { message_id: 1 } }), okBody({ ok: false, description: 'blocked' }), okBody({ ok: false }), okBody('plain', 403),
  ]],
  ['telegram.send', { credential: 'b', chatId: '', text: 'hi' }, [{}]],
  ['telegram.send', { chatId: '1', text: 'hi' }, [{}]],
  ['discord.send', { credential: 'w', content: 'yo {{ $json.v }}', username: 'Bot' }, [okBody({ id: '9' }), okBody({ message: 'Unknown Webhook' }, 404)]],
  ['discord.send', { mode: 'bot', credential: 'b', channelId: 'a/b', content: 'yo' }, [okBody({ id: '9' })]],
  ['discord.send', { credential: 'w', content: '' }, [{}]],
  ['db.supabase', { credential: 's', table: 't x', filters: [{ name: 'a', value: '{{ $json.v }}' }, { name: '', value: 'skip' }], limit: 0 }, [okBody([{ id: 1 }, 2]), okBody({ message: 'bad' }, 400)]],
  ['db.supabase', { credential: 's', operation: 'insert', table: 't', row: '{"a":1}' }, [okBody([{ a: 1 }])]],
  ['db.supabase', { credential: 's', operation: 'update', table: 't', filters: [{ name: 'id', value: 1 }], row: { b: 2 } }, [okBody([])]],
  ['db.supabase', { credential: 's', operation: 'delete', table: 't' }, [{}]],
  ['db.supabase', { credential: 's', operation: 'delete', table: 't', filters: [{ name: 'id', value: 'x' }] }, [okBody([{ id: 'x' }])]],
  ['db.supabase', { credential: 's', operation: 'drop', table: 't' }, [{}]],
  ['db.supabase', { credential: 's', table: '' }, [{}]],
  ['db.airtable', { credential: 'a', baseId: 'app', table: 'T', filterFormula: "{Done} = 'no'", limit: 3 }, [
    okBody({ records: [{ id: 'r', createdTime: 't', fields: { A: 1, id: 'shadow' } }, 5] }), okBody({ error: { type: 'X', message: 'nope' } }, 422),
  ]],
  ['db.airtable', { credential: 'a', operation: 'create', baseId: 'app', table: 'T', fields: '{{ $json }}' }, [okBody({ id: 'r', fields: {} })]],
  ['db.airtable', { credential: 'a', operation: 'update', baseId: 'app', table: 'T', fields: { a: 1 } }, [{}]],
  ['db.airtable', { credential: 'a', operation: 'update', baseId: 'app', table: 'T', recordId: 'rec', fields: 'not json' }, [okBody({ id: 'rec' })]],
  ['db.notion', { credential: 'n', databaseId: 'd', filter: '{"property":"Done","checkbox":{"equals":false}}', limit: 500 }, [okBody({ results: [{ id: 'p' }, 'x'] }), okBody({ results: 'x' })]],
  ['db.notion', { credential: 'n', operation: 'create', databaseId: 'd', properties: { Name: { title: [] } } }, [okBody({ id: 'p', url: 'u' })]],
  ['db.notion', { credential: 'n', operation: 'move', databaseId: 'd' }, [{}]],
  ['db.table', { table: 'notes', row: '{{ $json }}' }, [{ rows: [{ a: 1 }, 2] }, { error: 'disk full' }, {}]],
  ['db.table', { operation: 'update', table: 'notes', filters: [{ name: 'v', value: '{{ $json.v }}' }], row: 'nope' }, [{}]],
  ['db.table', { operation: 'shred', table: 'notes' }, [{}]],
  ['db.table', { operation: 'find', table: '' }, [{}]],
  ['google.sheets', { credential: 'g', spreadsheetId: 'S', range: 'A:B' }, [
    okBody({ values: [['n', 'n', 3], ['x'], 'bad', ['y', 'z', 'w', 'extra']] }), okBody({ values: [] }), okBody({}),
  ]],
  ['google.sheets', { credential: 'g', operation: 'append', spreadsheetId: 'S', range: 'Sheet 1', values: '{{ $json.v }}' }, [okBody({ updates: { updatedRows: 2 } }), okBody({})]],
  ['google.sheets', { credential: 'g', spreadsheetId: '', range: 'A' }, [{}]],
  ['google.gmail', { credential: 'g', to: 'Zoë <z@x.y>', subject: 'Plain', body: 'Ünïcode body 😀' }, [okBody({ id: 'm', threadId: 't' })]],
  ['google.gmail', { credential: 'g', to: '', subject: 's' }, [{}]],
  ['google.calendar', { credential: 'g', calendarId: 'team@x', summary: 'S', start: 'a', end: 'b', description: 'd' }, [okBody({ id: 'e' })]],
  ['google.calendar', { credential: 'g', calendarId: '', summary: 'S', start: 'a' }, [{}]],
  ['system.command', { command: 'echo {{ $json.v }}', workdir: '/tmp', timeout: 0 }, [
    { results: [{ exitCode: 0, stdout: 'a', stderr: '' }] }, { results: [{ exitCode: 1, stdout: '', stderr: '  oops  \n' }] },
    { results: [{ exitCode: 3 }] }, { results: [{ error: 'Termux not installed' }] }, { error: 'denied' }, { results: [] },
  ]],
  ['system.command', { target: 'ubuntu', command: 'false', ignoreExitCode: true }, [{ results: [{ exitCode: 1, stdout: '', stderr: 'x' }] }]],
  ['system.command', { target: 'windows', command: 'dir' }, [{}]],
  ['system.command', { command: '' }, [{}]],
  ['core.code', { code: 'return items' }, [{ results: [{ a: 1 }, 2, null, [3]] }, { results: null }, { results: { x: 1 } }, { error: 'SyntaxError' }]],
  ['core.code', { language: 'python', mode: 'eachItem', code: 'return {{ item }}', timeout: -1 }, [
    { results: [{ a: 1 }] }, { results: [[{ b: 1 }, 'c'], null] }, { results: 'x' },
  ]],
  ['core.code', { language: 'ruby', code: 'x' }, [{}]],
  ['core.code', { mode: 'some', code: 'x' }, [{}]],
  ['core.code', { code: '   ' }, [{}]],
  ['core.code', { code: 5 }, [{}]],
  ['core.executeWorkflow', { workflowId: 'child' }, [{ outputs: [[{ r: 1 }, 'x']] }, { outputs: [] }, { outputs: [1] }, { error: 'missing' }]],
  ['core.executeWorkflow', { workflowId: '{{ $json.v }}', mode: 'eachItem' }, [{ outputs: [[{ r: 1 }]] }, { outputs: [[{ r: 1 }], [{ r: 2 }]] }]],
  ['core.executeWorkflow', { workflowId: 'child', wait: false }, [{}]],
  ['core.executeWorkflow', { workflowId: '' }, [{}]],
  ['core.executeWorkflow', { workflowId: 'w', mode: 'x' }, [{}]],
  ['android.sms', { to: '+1 {{ $json.v }}', text: 'Hi' }, [{}, { error: 'no permission' }]],
  ['android.sms', { to: '' }, [{}]],
  ['email.send', { credential: 'm', to: 'a@b.c', subject: '{{ $json.v }}', text: 't', html: true }, [{}, { error: 'auth failed' }]],
  ['email.send', { credential: '', to: 'a@b.c' }, [{}]],
  ['email.send', { credential: 'm', to: '' }, [{}]],
  ['rss.read', { url: 'https://f.test/{{ $json.v }}' }, [{ feeds: [[{ title: 'a' }, 2, 'x']] }, { feeds: [{ title: 'one' }] }, { feeds: 'x' }, { error: 'offline' }]],
  ['rss.read', { url: '' }, [{}]],
  ['files', { operation: 'write', path: 'a/{{ $json.v }}.txt', content: '{{ $json.v }}' }, [{ results: [{ path: 'a', size: 1 }] }, { results: [] }]],
  ['files', { operation: 'list', path: '' }, [{ results: [[{ name: 'a' }, 1]] }, { results: [5] }]],
  ['files', { operation: 'read', path: '' }, [{}]],
  ['files', { operation: 'chmod', path: 'x' }, [{}]],
  ['http.request', { url: 'https://x.test', credential: '{{ $json.v }}' }, [okBody({ ok: 1 })]],
  ['google.drive', { credential: 'g', query: "name contains '{{ $json.v }}'" }, [okBody({ files: [{ id: '1' }, 2] }), okBody({})]],
  ['google.drive', { credential: 'g', operation: 'upload', name: 'n {{ $json.v }}', content: 'c', mimeType: '', folderId: 'F' }, [okBody({ id: 'x' })]],
  ['google.drive', { credential: 'g', operation: 'upload', name: '' }, [{}]],
  ['google.drive', { credential: 'g', operation: 'download', fileId: 'f/{{ $json.v }}' }, [okBody({ a: 1 }), { responses: [{ status: 200, headers: {}, body: 'plain' }] }]],
  ['google.drive', { credential: 'g', operation: 'download', fileId: '' }, [{}]],
  ['google.drive', { credential: 'g', operation: 'move' }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'Q {{ $json.v }}', system: 'S', model: 'm', webSearch: true, timeout: 0, maxSteps: 3, tools: [
    { kind: 'http', name: 'web', description: '', config: 'https://a/' }, { kind: 'http', name: 'web2', config: '' },
    { kind: 'command', name: 'sh', description: 'd' }, { kind: 'workflow', name: 'wf' }, { kind: 'table', name: 'db' },
  ] }, [
    okBody({ content: [{ type: 'thinking', thinking: 'x' }, { type: 'text', text: 'A' }, { type: 'text', text: 'B' }], stop_reason: 'end_turn' }),
    okBody({ content: [], stop_reason: 'refusal' }),
    okBody({ error: { message: 'bad' } }, 400),
    okBody('not an object'),
    { responses: [] },
    okBody({ content: 'x', stop_reason: 'max_tokens' }),
  ]],
  ['ai.agent', { credential: 'c', prompt: '' }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'ftp', name: 'a' }] }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'http', name: 'a b' }] }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'http', name: 'a' }, { kind: 'command', name: 'a' }] }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [1] }, [{}]],
  ['ai.agent', { credential: '', prompt: 'x' }, [{}]],
  ['ai.agent', {
    provider: 'claudeCode', system: 'S', prompt: 'Do {{ $json.v }}', model: 'sonnet', access: 'runCommands', webSearch: true,
    mcpServers: '{"docs": {"type": "http", "url": "https://d/mcp"}, "fs": {"command": "npx"}}', session: '{{ $json.v }}', maxSteps: 2.7, timeout: 0,
  }, [
    { replies: [{ text: 'ok', model: 'm', sessionId: 's', steps: 2, stopReason: 'success', costUsd: 0.1 }] },
    { replies: [{ text: 7 }, {}] }, { replies: [{ error: 'signed out' }] }, { replies: [3] }, { replies: 'x' }, { error: 'no Ubuntu' }, {},
  ]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: { a: {} }, folder: '/w' }, [{ replies: [{ text: 'done' }] }]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: '' }, [{ replies: [] }]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: '[1]' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: '{"a b": {}}' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: '{"a": 1}' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', mcpServers: '{bad' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', access: 'all' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: 'p', folder: 'rel' }, [{}]],
  ['ai.agent', { provider: 'claudeCode', prompt: '' }, [{}]],
  ['ai.agent', { provider: 'other', prompt: 'p' }, [{}]],
  ['mcp.client', { url: 'https://m/mcp', credential: 'c', name: 'search', arguments: '{"q": "{{ $json.v }}"}', timeout: 5 }, [
    { results: [{ result: { content: [{ type: 'text', text: 'a' }, { type: 'image', data: 'x' }, { type: 'text', text: 'b' }] } }] },
    { results: [{ result: { content: [], structuredContent: { n: 1 } } }] },
    { results: [{ result: { content: [{ type: 'text', text: 'boom' }], isError: true } }] },
    { results: [{ result: { isError: true } }] },
    { results: [{ error: 'unknown tool' }] }, { results: [{ result: 3 }] }, { results: [5] }, { results: 'x' }, { error: 'down' }, {},
  ]],
  ['mcp.client', { url: 'http://m', name: 'p', operation: 'getPrompt', arguments: { a: '{{ $json.v }}' } }, [
    { results: [{ result: { messages: [{ role: 'user' }] } }] },
  ]],
  ['mcp.client', { transport: 'stdio', command: 'srv', operation: 'readResource', uri: 'file:///{{ $json.v }}', timeout: 0 }, [
    { results: [{ result: { contents: [{ uri: 'u', text: 'hi' }, { uri: 'v', blob: 'AA' }] } }] }, { results: [{ result: {} }] },
  ]],
  ['mcp.client', { transport: 'stdio', command: 'srv', operation: 'listTools' }, [{ results: [{ result: { tools: [{ name: 't' }] } }] }]],
  ['mcp.client', { url: 'https://m', operation: 'listResources' }, [{ results: [{ result: { resources: [] } }] }]],
  ['mcp.client', { url: 'https://m', operation: 'listPrompts', arguments: '' }, [{ results: [{ result: { prompts: [] } }] }]],
  ['mcp.client', { url: 'https://m', name: 't', arguments: '' }, [{ results: [{ result: { content: [] } }] }]],
  ['mcp.client', { url: 'https://m', name: 't', arguments: '[1]' }, [{}]],
  ['mcp.client', { url: 'https://m', name: 't', arguments: '{bad' }, [{}]],
  ['mcp.client', { url: 'https://m', name: '' }, [{}]],
  ['mcp.client', { url: 'https://m', operation: 'getPrompt' }, [{}]],
  ['mcp.client', { url: 'https://m', operation: 'readResource' }, [{}]],
  ['mcp.client', { url: 'https://m', operation: 'nope' }, [{}]],
  ['mcp.client', { url: 'ftp://m', name: 't' }, [{}]],
  ['mcp.client', { transport: 'stdio', name: 't' }, [{}]],
  ['mcp.client', { transport: 'ws', name: 't' }, [{}]],
  ['mcp.client', { transport: 'saved', server: 'S', operation: 'listTools' }, [{ results: [{ result: { tools: [] } }] }]],
  ['mcp.client', { transport: 'saved', operation: 'listTools' }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'Q {{ $json.v }}', timeout: 9, tools: [
    { kind: 'command', name: 'sh' }, { kind: 'mcp', name: 'docs', config: 'https://d/mcp' }, { kind: 'mcp', name: 'fs', config: 'npx fs' },
  ] }, [
    { results: [
      { tools: [{ name: 'search', description: 'S', inputSchema: { type: 'object', required: ['q'] } }, { name: 'a.b/c ü😀' }, { name: '' }, 1, { name: 7 }] },
      { tools: [{ name: 'search', description: '' }, { name: 'x'.repeat(80) }, { name: 'x'.repeat(81) }] },
    ] },
    { results: [{ tools: 'none' }, {}] }, { results: [{ error: 'offline' }, {}] }, { results: [5, {}] }, { results: [{}] }, { results: 'x' },
    { error: 'down' }, {},
  ]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'mcp', name: 'sh__x', config: 'c' }, { kind: 'http', name: 'sh__x_y' }] }, [
    { results: [{ tools: [{ name: 'x y' }, { name: 'x' }] }] },
  ]],
  ['trigger.mcp', { name: 'n', inputSchema: '{bad' }, [{}]],
  ['trigger.calendar', { event: 'end', minutes: 3 }, [{}]],
  ['android.calendar', { from: '{{ $json.v }}', to: 'b', calendar: 'c', field: 'f' }, [
    { events: [{ title: 't' }] }, { events: 'x' }, {}, { error: 'denied' },
  ]],
  ['android.calendar', { operation: 'freeSlots', minutes: '{{ $json.v }}', dayStart: ' 7:5 ', dayEnd: '23:59' }, [{ slots: [1] }]],
  ['android.calendar', { operation: 'freeSlots', minutes: -3, dayStart: '7:05', dayEnd: '24:00' }, [{}]],
  ['android.calendar', { operation: 'freeSlots', dayStart: '07:60' }, [{}]],
  ['android.calendar', { operation: 'freeSlots', dayStart: '123:00' }, [{}]],
  ['android.calendar', { operation: 'freeSlots', dayStart: '٠٧:٣٠' }, [{}]],
  ['android.calendar', { operation: 'create', title: 'T {{ $json.v }}', start: 's', end: 'e', allDay: 'yes', location: 'l', description: 'd' }, [
    { results: [{ id: 1 }] }, { results: [] }, { results: 'x' }, { error: 'no' },
  ]],
  ['android.calendar', { operation: 'create', title: '', start: 's' }, [{}]],
  ['android.calendar', { operation: 'create', title: 't', start: '' }, [{}]],
  ['android.calendar', { operation: 'nope' }, [{}]],
  ['android.ask', { title: '', question: 'Q {{ $json.v }}', buttons: 'A,, B ,C', reply: false, timeout: '{{ $json.v }}', field: 'a' }, [
    { button: 'A', text: 5 }, { timedOut: 'yes' }, { timedOut: true, button: 7 }, {}, { error: 'dismissed' },
  ]],
  ['android.ask', { question: 'q', buttons: '', reply: true, timeout: -1 }, [{ text: 'hi' }]],
  ['android.ask', { question: 'q', buttons: ' ' }, [{}]],
  ['android.ask', { question: 'q', buttons: 'a,b,c,d' }, [{}]],
  ['android.ask', { question: '' }, [{}]],
  ['android.listen', { prompt: 'P', language: '{{ $json.v }}', seconds: 2.5 }, [{ text: 'hi', confidence: 0.5 }, {}, { error: 'no mic' }]],
  ['android.listen', { seconds: -4 }, [{}]],
  ['android.sound', { mode: 'dndAlarms', field: 's' }, [{ ringer: 'normal', dnd: 'off' }, { error: 'no access' }]],
  ['android.sound', { mode: 'read' }, [{ ringer: 'vibrate' }]],
  ['android.sound', { mode: 'x' }, [{}]],
  ['android.contacts', { query: '{{ $json.v }}', limit: 3.9 }, [
    { results: [[{ name: 'A' }]] }, { results: [] }, { results: 'x' }, { error: 'denied' },
  ]],
  ['android.contacts', { query: '' }, [{}]],
  ['android.contacts', { operation: 'add', name: 'N {{ $json.v }}', phone: 'p', email: 'e' }, [{ results: [{ id: 'c1' }] }]],
  ['android.contacts', { operation: 'add', name: '' }, [{}]],
  ['android.contacts', { operation: 'remove' }, [{}]],
  ['android.clock', { time: '23:59', days: 'SUN,Saturday, wed ,', label: 'L {{ $json.v }}' }, [{}, { notified: true }, { error: 'no clock app' }]],
  ['android.clock', { time: '7:5' }, [{}]],
  ['android.clock', { time: '' }, [{}]],
  ['android.clock', { days: 'mo' }, [{}]],
  ['android.clock', { days: 'Ünday' }, [{}]],
  ['android.clock', { operation: 'timer', seconds: '{{ $json.v }}' }, [{}]],
  ['android.clock', { operation: 'timer', seconds: 0.5 }, [{}]],
  ['android.clock', { operation: 'showAlarms', label: 'x' }, [{}]],
  ['android.clock', { operation: 'snooze' }, [{}]],
  ['android.photo', { source: 'gallery', multiple: true, pages: -2, pdf: false }, [
    { files: [{ path: 'a' }, 'x', { path: 'b' }] }, { files: [], cancelled: true }, { files: [1] }, { error: 'not on screen' }, {},
  ]],
  ['android.photo', { source: 'scan', pages: '{{ $json.v }}' }, [{ files: [{ path: 'p' }], pdf: { path: 'x.pdf' } }, { files: [{}], pdf: 'no' }]],
  ['android.photo', { source: 'x' }, [{}]],
  ['browser.run', { url: 'https://a.example/{{ $json.v }}', steps: 'click text="{{ $json.v }}"', visible: true, fast: false, timeout: '{{ $json.v }}', field: 'b' }, [
    { results: [{ url: 'u', data: {} }] }, { results: [{ error: 'gone' }] }, { results: [3] }, { results: [] }, { results: 'x' },
    { error: 'no browser' }, {},
  ]],
  ['browser.run', { url: 'http://x', steps: '' }, [{ results: [{}] }]],
  ['browser.run', { url: 'ftp://x' }, [{}]],
  ['browser.run', { url: '' }, [{}]],
  ['ai.agent', { credential: 'c', prompt: 'x', tools: [{ kind: 'browser', name: 'web', config: 'example.com' }, { kind: 'browser', name: 'web2' }] }, [
    okBody({ content: [{ type: 'tool_use', id: 't', name: 'web', input: { action: 'open', url: 'https://example.com' } }], stop_reason: 'tool_use' }),
  ]],
];
const INTEGRATION_ITEMS = [[{ v: 'a&b=c' }], [{ v: 1 }, { v: [1, 'x'] }], [{ v: { k: 'ü' } }]];
for (const [type, params, answers] of INTEGRATIONS) {
  const wf = workflow(
    [{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'n', name: 'Node', type, params }],
    [{ from: 'start', to: 'n' }],
  );
  for (const items of INTEGRATION_ITEMS) {
    for (const answer of answers) {
      // Multi-item runs need one response per item; repeat the single canned one.
      const fitted = isRecord(answer) && Array.isArray(answer['responses']) && answer['responses'].length === 1
        ? { responses: items.map(() => (answer['responses'] as unknown[])[0]) }
        : isRecord(answer) && Array.isArray(answer['results']) && answer['results'].length === 1
          ? { results: items.map(() => (answer['results'] as unknown[])[0]) }
          : answer;
      session(wf, 'start', items, [fitted]);
    }
  }
  add('validateWorkflow', wf);
}

// Multi-step sessions: the agent's tool loop, loops, retries and pinned data.
const toolUse = (id: string, name: string, input: unknown) =>
  okBody({ content: [{ type: 'text', text: 'Let me check.' }, { type: 'tool_use', id, name, input }], stop_reason: 'tool_use' });
const endTurn = (text: string) => okBody({ content: [{ type: 'text', text }], stop_reason: 'end_turn' });
const agentWf = (params: object) => workflow(
  [{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'n', name: 'Agent', type: 'ai.agent', params: { credential: 'c', prompt: '{{ $json.q }}', ...params } }],
  [{ from: 'start', to: 'n' }],
);
const agentTools = { tools: [{ kind: 'http', name: 'web', config: 'https://a/' }, { kind: 'command', name: 'sh', config: 'ubuntu' }] };
for (const [params, items, answers] of [
  [agentTools, [{ q: 'a' }], [toolUse('t1', 'web', { url: 'https://a/x' }), { results: [{ content: 'r1', isError: false }] }, endTurn('done')]],
  [agentTools, [{ q: 'a' }, { q: 'b' }], [endTurn('A'), toolUse('t2', 'ghost', {}), { results: [{ content: 'nope', isError: true }] }, endTurn('B')]],
  [agentTools, [{ q: 'a' }], [toolUse('t1', 'sh', { command: 'ls' }), { results: [] }]],
  [agentTools, [{ q: 'a' }], [toolUse('t1', 'sh', { command: 'ls' }), { error: 'Ubuntu is not installed' }]],
  [agentTools, [{ q: 'a' }], [toolUse('t1', 'sh', { command: 'ls' }), { results: ['plain'] }, okBody({ content: [], stop_reason: 'pause_turn' }), endTurn('ok')]],
  [{ ...agentTools, maxSteps: 2 }, [{ q: 'a' }], [toolUse('t1', 'sh', {}), { results: [{ content: 1 }] }, toolUse('t2', 'sh', {}), { results: [{ content: 2 }] }]],
  [{ maxSteps: 0 }, [{ q: 'a' }], [okBody({ content: [], stop_reason: 'pause_turn' })]],
] as [object, unknown[], unknown[]][]) {
  session(agentWf(params), 'start', items, answers);
}

const loopWf = (batchSize: unknown, back = true) => workflow(
  [
    { id: 'start', name: 'Start', type: 'trigger.manual' },
    { id: 'loop', name: 'Loop', type: 'core.loop', params: { batchSize } },
    { id: 'tag', name: 'Tag', type: 'core.set', params: { fields: [{ name: 'seen', value: '{{ $json.n }}' }] } },
    { id: 'end', name: 'End', type: 'core.noop' },
  ],
  [{ from: 'start', to: 'loop' }, { from: 'loop', output: 1, to: 'tag' }, ...(back ? [{ from: 'tag', to: 'loop' }] : []), { from: 'loop', output: 0, to: 'end' }],
);
for (const size of [1, 2, 3, 0, -1, 2.7, '{{ 2 }}', 'x']) {
  session(loopWf(size), 'start', [{ n: 1 }, { n: 2 }, { n: 3 }], []);
}
session(loopWf(1, false), 'start', [{ n: 1 }, { n: 2 }], []);
session(loopWf(5), 'start', [], []);

const retryWf = (extra: object) => workflow(
  [{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'h', name: 'Fetch', type: 'http.request', params: { url: 'https://x.test' }, ...extra }],
  [{ from: 'start', to: 'h' }],
);
const offline = { responses: [{ error: 'offline' }] };
for (const extra of [
  { retryOnFail: true }, { retryOnFail: true, maxTries: 1 }, { retryOnFail: true, maxTries: 50, waitBetweenTries: -5 },
  { retryOnFail: true, maxTries: 2.9, waitBetweenTries: 1e9 }, { retryOnFail: 'yes', maxTries: 'x' }, { retryOnFail: true, continueOnFail: true, maxTries: 2 },
]) {
  session(retryWf(extra), 'start', [{}], [offline, {}, offline, {}, offline, {}, offline]);
  session(retryWf(extra), 'start', [{}], [offline, {}, okBody({ ok: true })]);
}

for (const [pinned, use] of [[[{ cached: 1 }], true], [[{ cached: 1 }], false], [[], true], ['x', true], [[1], true]] as [unknown, boolean][]) {
  const nodes = [
    { id: 'start', name: 'Start', type: 'trigger.manual', pinned: [{ fromPin: true }] },
    { id: 'h', name: 'Fetch', type: 'http.request', params: { url: 'https://x.test' }, pinned: pinned as object[] },
    { id: 'end', name: 'End', type: 'core.noop' },
  ];
  session(workflow(nodes, [{ from: 'start', to: 'h' }, { from: 'h', to: 'end' }], {}, { usePinnedData: use }), 'start', [{ live: true }], [okBody({ live: 1 })]);
}

// Malformed inputs.
const BAD_WORKFLOWS = [
  '', 'null', '{}', '{"nodes":[1]}', '{"nodes":[{"id":""}]}', '{"nodes":[{"id":"a"}]}', '{"nodes":[{"id":"a","type":"core.noop"}],"connections":{}}',
  '{"nodes":[{"id":"start","type":"trigger.manual"}],"connections":[5]}', '{"nodes":[{"id":"start","type":"trigger.manual","params":[1]}],"connections":[{"from":"start","to":"start","output":-1,"input":1.5}]}',
];
for (const wf of BAD_WORKFLOWS) {
  add('startExecution', wf, 'start', '[]', NOW);
  add('validateWorkflow', wf);
}
for (const [items, now] of [['[1]', NOW], ['{}', NOW], ['nope', NOW], ['[]', Number.NaN], ['[]', -8.64e15], ['[]', 8.64e15 + 1], ['[]', 1.9], ['[]', -1.9]] as const) {
  add('startExecution', fixtures.setAndIf, 'start', items, now);
}
add('startExecution', fixtures.setAndIf, 'ghost', '[]', NOW);

const waiting = startExecution(fixtures.httpThenNotify, 'hook', '[{"body":{"id":1}}]', NOW);
const parsed = JSON.parse(waiting) as Record<string, unknown>;
const mutate = (patch: object): string => JSON.stringify({ ...parsed, ...patch });
for (const state of [
  'nope', '[]', mutate({ status: 'success' }), mutate({ steps: -1 }), mutate({ steps: 1.5 }), mutate({ startedAt: 'x' }), mutate({ runs: {} }),
  mutate({ pending: null }), mutate({ pending: { node: 'ghost', inputs: [], effect: {} } }), mutate({ pending: { node: 'http', inputs: [[1]], effect: {} } }),
  mutate({ queue: [{ node: 'note', input: 0, items: 'x' }] }), mutate({ queue: [{ node: 'note', input: -1, items: [] }] }),
  mutate({ waiting: { a: 1 } }), mutate({ memory: 5 }), mutate({ memory: { x: [1] } }),
  mutate({ pending: { ...(parsed['pending'] as object), attempt: 0 } }), mutate({ pending: { ...(parsed['pending'] as object), attempt: 1.5 } }),
  mutate({ pending: { ...(parsed['pending'] as object), attempt: 2, retry: true, memo: { a: 1 } } }), mutate({ queue: [{ node: 'note', input: 64, items: [] }] }), mutate({ startedAt: 1e400 }), mutate({ last: { a: [1] } }), mutate({ pending: { node: 'hook', inputs: [], effect: {} } }),
]) {
  add('resumeExecution', fixtures.httpThenNotify, state, '{"responses":[{"status":200,"body":"{}"}]}', NOW);
}
for (const result of ['nope', '[]', '1', '{"responses":"x"}']) add('resumeExecution', fixtures.httpThenNotify, waiting, result, NOW);

for (const wf of Object.values(fixtures)) add('validateWorkflow', wf);
add('nodeCatalog');

process.stdout.write(cases.map((c) => JSON.stringify(c)).join('\n') + '\n');
