import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { nodeCatalog, resumeExecution, startExecution, validateWorkflow } from '../src/api.ts';
import { fixtures } from './fixtures.ts';

const NOW = Date.UTC(2026, 10, 21, 8, 30);

type State = {
  status: string;
  error: string | null;
  steps: number;
  pending: { node: string; effect: Record<string, unknown> } | null;
  last: Record<string, Record<string, unknown>[]>;
  runs: { name: string; error: string | null }[];
};

const run = (wf: string, items: unknown[], trigger = 'start'): [string, State] => {
  const json = startExecution(wf, trigger, JSON.stringify(items), NOW);
  return [json, JSON.parse(json) as State];
};

const resume = (wf: string, stateJson: string, result: unknown): [string, State] => {
  const json = resumeExecution(wf, stateJson, JSON.stringify(result), NOW + 1000);
  return [json, JSON.parse(json) as State];
};

describe('pure workflows', () => {
  it('sets fields and branches on a condition', () => {
    const [, s] = run(fixtures.setAndIf, [{ name: 'Ann', age: 30 }, { name: 'Bo', age: '12' }]);
    assert.equal(s.status, 'success');
    assert.deepEqual(s.last['Yes'], [
      { name: 'Ann', age: 30, greeting: 'Hi, Ann', meta: { index: 0, at: '2026-11-21T08:30:00.000Z' } },
    ]);
    assert.deepEqual(s.last['No'], [{ minor: 'Bo' }]);
  });

  it('runs one empty item when the trigger gets none', () => {
    const [, s] = run(fixtures.setAndIf, []);
    assert.deepEqual(s.last['Start'], [{}]);
  });

  it('splits, dedupes, filters, sorts, limits and aggregates', () => {
    const orders = [
      { id: 1, total: 10, tags: ['vip'] },
      { id: 2, total: 80, tags: [] },
      { id: 2, total: 99, tags: [] },
      { id: 3, total: 60, tags: [] },
      { id: 4, total: 5, tags: [] },
    ];
    const [, s] = run(fixtures.dataPipeline, [{ orders }]);
    assert.equal(s.status, 'success');
    assert.deepEqual(s.last['Collect'], [{ id: [2, 3] }]);
  });

  it('routes with switch and waits for both merge inputs', () => {
    const [, s] = run(fixtures.switchMerge, [{ kind: 'a' }, { kind: 'bee' }, { kind: 'z' }]);
    assert.equal(s.status, 'success');
    assert.deepEqual(s.last['Merge'], [{ kind: 'a', route: 'A' }, { kind: 'bee', route: 'B' }]);
    assert.deepEqual(s.last['Pair'], [{ kind: 'z', route: 'A' }]);
  });

  it('continues past failing nodes that allow it, then stops on a hard failure', () => {
    const [, s] = run(fixtures.failures, [{ a: 'abc' }]);
    assert.equal(s.status, 'error');
    assert.equal(s.error, "Boom: NodeError: field 'missing' is not a list");
    assert.deepEqual(s.last['Disabled'], [{ error: 'ExpressionError: unknown method reverse' }]);
  });

  it('stops workflows that loop forever', () => {
    const [, s] = run(fixtures.loop, [{}]);
    assert.equal(s.status, 'error');
    assert.equal(s.error, 'execution stopped after 5000 node runs');
  });
});

describe('effects', () => {
  it('pauses for HTTP, notifications and the webhook response', () => {
    let [json, s] = run(fixtures.httpThenNotify, [{ body: { id: 7 } }], 'hook');
    assert.equal(s.status, 'waiting');
    assert.deepEqual(s.pending?.effect, {
      type: 'http',
      requests: [{
        method: 'POST',
        url: 'https://api.example.com/users/7',
        headers: { Authorization: 'Bearer secret', 'Content-Type': 'application/json' },
        body: '{"id":7}',
        timeoutMs: 30000,
      }],
    });
    [json, s] = resume(fixtures.httpThenNotify, json, { responses: [{ status: 200, headers: {}, body: '{"name":"Zed"}' }] });
    assert.deepEqual(s.pending?.effect, { type: 'notify', notifications: [{ title: 'User Zed', body: '7' }] });
    [json, s] = resume(fixtures.httpThenNotify, json, {});
    assert.deepEqual(s.pending?.effect, { type: 'respond', status: 201, contentType: 'application/json', body: [{ name: 'Zed' }] });
    [, s] = resume(fixtures.httpThenNotify, json, {});
    assert.equal(s.status, 'success');
  });

  it('fails the run on HTTP errors', () => {
    const [json] = run(fixtures.httpThenNotify, [{ body: { id: 7 } }], 'hook');
    const [, s] = resume(fixtures.httpThenNotify, json, { responses: [{ status: 404, body: 'nope' }] });
    assert.equal(s.error, 'Fetch: NodeError: request failed with status 404');
  });

  it('feeds device readings into later nodes', () => {
    let [json, s] = run(fixtures.deviceNodes, [{}]);
    const results = [
      { level: 42, charging: false },
      { latitude: 14.5, longitude: 121, accuracy: 9 },
      { text: 'copied' },
      {}, {}, {}, {}, {},
    ];
    const effects: unknown[] = [];
    for (const result of results) {
      effects.push(s.pending?.effect);
      [json, s] = resume(fixtures.deviceNodes, json, result);
    }
    assert.equal(s.status, 'success');
    assert.deepEqual(effects.slice(3), [
      { type: 'speak', text: 'Battery at 42 percent' },
      { type: 'vibrate', ms: 420 },
      { type: 'wait', ms: 1500 },
      { type: 'clipboardWrite', text: '14.5,121' },
      { type: 'openUrl', url: 'geo:14.5,121' },
    ]);
    assert.deepEqual(s.last['Map'], [{
      battery: { level: 42, charging: false },
      pos: { latitude: 14.5, longitude: 121, accuracy: 9 },
      clipboard: 'copied',
    }]);
  });

  it('rejects results for executions that are not waiting', () => {
    const [json] = run(fixtures.setAndIf, [{}]);
    assert.throws(() => resumeExecution(fixtures.setAndIf, json, '{}', NOW), {
      message: 'InputError: execution is not waiting for an effect result',
    });
  });
});

describe('inputs and validation', () => {
  it('rejects malformed documents', () => {
    const fails = (wf: string, message: string): void => {
      assert.throws(() => startExecution(wf, 'start', '[]', NOW), { message });
    };
    fails('nope', 'InputError: workflow is not valid JSON');
    fails('[]', 'InputError: workflow must be an object');
    fails('{"nodes":{}}', 'InputError: workflow.nodes must be an array');
    fails('{"nodes":[{"type":"core.noop"}]}', 'InputError: node 0 has no id');
    fails('{"nodes":[]}', 'InputError: unknown trigger node start');
    fails(`{"nodes":[],"x":${'['.repeat(70)}${']'.repeat(70)}}`, 'InputError: workflow is nested too deeply');
    assert.throws(() => startExecution(fixtures.setAndIf, 'start', '[1]', NOW), { message: 'InputError: items must be a list of objects' });
    assert.throws(() => startExecution(fixtures.setAndIf, 'start', '[]', Number.NaN), { message: 'InputError: now is out of range' });
  });

  it('lists every problem in a workflow', () => {
    assert.deepEqual(JSON.parse(validateWorkflow(fixtures.invalid)), [
      'workflow has no trigger node',
      'duplicate node id x',
      'duplicate node name x',
      'x: unknown node type core.mystery',
      'x: ExpressionError: unexpected end of expression',
      'connection 0: unknown target node ghost',
    ]);
    assert.deepEqual(JSON.parse(validateWorkflow(fixtures.httpThenNotify)), []);
  });

  it('describes every node type', () => {
    const catalog = JSON.parse(nodeCatalog()) as { type: string; group: string }[];
    assert.ok(catalog.some((n) => n.type === 'http.request' && n.group === 'network'));
    assert.equal(new Set(catalog.map((n) => n.type)).size, catalog.length);
  });
});
