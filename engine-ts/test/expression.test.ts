import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { evaluateTemplate } from '../src/api.ts';

const ev = (template: string, ctx: object = {}): unknown => JSON.parse(evaluateTemplate(template, JSON.stringify(ctx)));

describe('templates', () => {
  it('keeps the type of a single expression', () => {
    assert.equal(ev('{{ 1 + 2 }}'), 3);
    assert.deepEqual(ev('{{ [1, "a", null] }}'), [1, 'a', null]);
    assert.equal(ev('{{ $json.ok }}', { $json: { ok: true } }), true);
  });

  it('splices several segments as text', () => {
    assert.equal(ev('Hi {{ $json.name }}, you have {{ $json.n }} items', { $json: { name: 'Ann', n: 3 } }), 'Hi Ann, you have 3 items');
    assert.equal(ev('null renders as {{ null }}nothing'), 'null renders as nothing');
    assert.equal(ev('obj {{ $json }}', { $json: { a: [1] } }), 'obj {"a":[1]}');
  });

  it('treats unclosed braces as text', () => {
    assert.equal(ev('a {{ b'), 'a {{ b');
    assert.equal(ev('plain'), 'plain');
  });
});

describe('operators', () => {
  it('follows JavaScript arithmetic and concatenation', () => {
    assert.equal(ev('{{ 7 % 3 * 2 - 1 }}'), 1);
    assert.equal(ev('{{ "a" + 1 }}'), 'a1');
    assert.equal(ev('{{ true + 1 }}'), 2);
    assert.equal(ev('{{ 1 / 0 }}'), null, 'Infinity serializes as null');
    assert.equal(ev('{{ "" + 1 / 0 }}'), 'Infinity');
    assert.equal(ev('{{ 0.1 + 0.2 }}'), 0.30000000000000004);
  });

  it('compares deeply and orders strings by code unit', () => {
    assert.equal(ev('{{ [1, [2]] == [1, [2]] }}'), true);
    assert.equal(ev('{{ $json.a == $json.b }}', { $json: { a: { x: 1 }, b: { x: 1 } } }), true);
    assert.equal(ev('{{ "B" < "a" }}'), true);
    assert.equal(ev('{{ "10" < 9 }}'), false);
    assert.equal(ev('{{ "x" < 1 }}'), false);
  });

  it('short-circuits logical operators', () => {
    assert.equal(ev('{{ 0 || "fallback" }}'), 'fallback');
    assert.equal(ev('{{ 0 ?? "unused" }}'), 0);
    assert.equal(ev('{{ null ?? "used" }}'), 'used');
    assert.equal(ev('{{ false && $missing }}'), false);
    assert.equal(ev('{{ 1 > 0 ? "yes" : "no" }}'), 'yes');
  });
});

describe('members and methods', () => {
  const ctx = { $json: { user: { name: ' Ann ', tags: ['a', 'b'] } } };

  it('reads nested data and yields null for missing paths', () => {
    assert.equal(ev('{{ $json.user.tags[1] }}', ctx), 'b');
    assert.equal(ev('{{ $json.user.tags.length }}', ctx), 2);
    assert.equal(ev('{{ $json.nope.deeper }}', ctx), null);
    assert.equal(ev('{{ $json.user["name"].trim() }}', ctx), 'Ann');
  });

  it('supports string methods', () => {
    assert.equal(ev('{{ "Hello".toUpperCase() }}'), 'HELLO');
    assert.deepEqual(ev('{{ "a,b,,c".split(",") }}'), ['a', 'b', '', 'c']);
    assert.equal(ev('{{ "aXbXc".replace("X", "-") }}'), 'a-bXc');
    assert.equal(ev('{{ "aXbXc".replaceAll("X", "-") }}'), 'a-b-c');
    assert.equal(ev('{{ "abcdef".slice(-3, -1) }}'), 'de');
    assert.equal(ev('{{ "abc".indexOf("c") }}'), 2);
  });

  it('supports list methods', () => {
    assert.equal(ev('{{ [1, null, "x"].join("|") }}'), '1||x');
    assert.equal(ev('{{ [1, 2, 3].includes(2) }}'), true);
    assert.equal(ev('{{ [1, 2, 3].last() }}'), 3);
    assert.deepEqual(ev('{{ [1, 2, 3].slice(1) }}'), [2, 3]);
  });

  it('supports Math, JSON and conversions', () => {
    assert.equal(ev('{{ Math.round(2.5) }}'), 3);
    assert.equal(ev('{{ Math.round(-2.5) }}'), -2);
    assert.equal(ev('{{ Math.max(1, "7", 3) }}'), 7);
    assert.equal(ev('{{ JSON.parse("{\\"a\\":1}").a }}'), 1);
    assert.equal(ev('{{ JSON.stringify([1, "a"]) }}'), '[1,"a"]');
    assert.equal(ev('{{ Number(" 42 ") + 1 }}'), 43);
    assert.equal(ev('{{ String(12.5) }}'), '12.5');
  });
});

describe('errors', () => {
  const fails = (template: string, message: string): void => {
    assert.throws(() => evaluateTemplate(template, '{}'), { message });
  };

  it('reports syntax errors', () => {
    fails('{{ 1 + }}', 'ExpressionError: unexpected end of expression');
    fails('{{ }}', 'ExpressionError: empty expression');
    fails('{{ "open }}', 'ExpressionError: unterminated string');
    fails('{{ 1 # 2 }}', 'ExpressionError: unexpected character');
    fails(`{{ ${'('.repeat(70)}1${')'.repeat(70)} }}`, 'ExpressionError: expression is nested too deeply');
  });

  it('reports unknown names', () => {
    fails('{{ $nope }}', 'ExpressionError: unknown variable $nope');
    fails('{{ Math.sqrt(4) }}', 'ExpressionError: unknown function Math.sqrt');
    fails('{{ "a".reverse() }}', 'ExpressionError: unknown method reverse');
  });

  it('rejects a bad context', () => {
    assert.throws(() => evaluateTemplate('x', '[1]'), { message: 'InputError: context must be an object' });
    assert.throws(() => evaluateTemplate('x', '{'), { message: 'InputError: context is not valid JSON' });
  });
});
