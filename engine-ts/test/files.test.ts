import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { resumeExecution, startExecution } from '../src/api.ts';
import { workflow } from './fixtures.ts';

const NOW = Date.UTC(2026, 10, 22, 12);
const manual = { id: 'start', name: 'Start', type: 'trigger.manual' };
const one = (type: string, params: object) =>
  workflow([manual, { id: 'n', name: 'Step', type, params }], [{ from: 'start', to: 'n' }]);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const start = (wf: string, items: unknown[]): [string, any] => {
  const json = startExecution(wf, 'start', JSON.stringify(items), NOW);
  return [json, JSON.parse(json)];
};
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const resume = (wf: string, state: string, result: unknown): any =>
  JSON.parse(resumeExecution(wf, state, JSON.stringify(result), NOW + 1));
const ref = { path: 'shared/123-photo.jpg', name: 'photo.jpg', mimeType: 'image/jpeg', size: 2048 };

describe('files between steps', () => {
  it('HTTP sends a file as the body and saves a response as a file', () => {
    const wf = one('http.request', { method: 'PUT', url: 'https://x.io/up', sendFile: '{{ $json.file }}', responseFormat: 'file' });
    const [json, s] = start(wf, [{ file: ref }]);
    const req = s.pending.effect.requests[0];
    assert.equal(req.file, 'shared/123-photo.jpg');
    assert.equal(req.body, null);
    assert.equal(req.headers['Content-Type'], 'image/jpeg');
    assert.equal(req.saveAs, 'file');
    const saved = { path: 'downloads/up.bin', name: 'up.bin', mimeType: 'application/octet-stream', size: 3 };
    const done = resume(wf, json, { responses: [{ status: 200, headers: {}, body: JSON.stringify(saved) }] });
    assert.deepEqual(done.last['Step'], [{ file: saved }]);
  });

  it('Telegram sends a photo or a document, the text as caption', () => {
    const [, photo] = start(one('telegram.send', { credential: 't', chatId: '42', text: 'Look', file: 'a/cat.PNG' }), [{}]);
    const req = photo.pending.effect.requests[0];
    assert.match(req.url, /sendPhoto$/);
    assert.deepEqual(req.multipart, [
      { name: 'chat_id', value: '42' },
      { name: 'photo', file: 'a/cat.PNG' },
      { name: 'caption', value: 'Look' },
    ]);
    const [, doc] = start(one('telegram.send', { credential: 't', chatId: '42', text: '', file: 'r.pdf' }), [{}]);
    assert.match(doc.pending.effect.requests[0].url, /sendDocument$/);
  });

  it('Discord attaches a file next to the message', () => {
    const [, s] = start(one('discord.send', { mode: 'webhook', credential: 'd', content: '', username: 'Bot', file: 'x.zip' }), [{}]);
    assert.deepEqual(s.pending.effect.requests[0].multipart, [
      { name: 'payload_json', value: '{"content":"","username":"Bot"}' },
      { name: 'files[0]', file: 'x.zip' },
    ]);
    const [, none] = start(one('discord.send', { mode: 'webhook', credential: 'd', content: '' }), [{}]);
    assert.equal(none.error, 'Step: NodeError: message is required');
  });

  it('email attachments from a list, a reference or nothing', () => {
    const wf = (attachments: string) => one('email.send', { credential: 'e', to: 'a@b.c', subject: 's', text: 't', attachments });
    const [, list] = start(wf('a.pdf, b.png'), [{}]);
    assert.deepEqual(list.pending.effect.messages[0].attachments, ['a.pdf', 'b.png']);
    const [, fromRef] = start(wf('{{ $json.file }}'), [{ file: ref }]);
    assert.deepEqual(fromRef.pending.effect.messages[0].attachments, ['shared/123-photo.jpg']);
    const [, plain] = start(wf(''), [{}]);
    assert.equal('attachments' in plain.pending.effect.messages[0], false);
  });

  it('Drive uploads any file and downloads as a file', () => {
    const [, up] = start(one('google.drive', { credential: 'g', operation: 'upload', file: 'docs/report.pdf', mimeType: 'text/plain' }), [{}]);
    assert.deepEqual(up.pending.effect.requests[0].related, {
      metadata: { name: 'report.pdf' }, file: 'docs/report.pdf', mimeType: 'application/pdf',
    });
    const wf = one('google.drive', { credential: 'g', operation: 'download', fileId: 'abc', downloadAs: 'file' });
    const [json, down] = start(wf, [{}]);
    assert.equal(down.pending.effect.requests[0].saveAs, 'file');
    const done = resume(wf, json, { responses: [{ status: 200, headers: {}, body: JSON.stringify(ref) }] });
    assert.deepEqual(done.last['Step'], [{ fileId: 'abc', file: ref }]);
  });

  it('AI Chat looks at an image, per provider', () => {
    const marker = '@@flowdroid-file-base64:p/cat.jpg@@';
    const [, claude] = start(one('ai.chat', { provider: 'anthropic', credential: 'c', prompt: 'What is this?', image: 'p/cat.jpg' }), [{}]);
    const cr = claude.pending.effect.requests[0];
    assert.equal(cr.inlineFiles, true);
    assert.ok(cr.body.includes(marker));
    assert.ok(cr.body.includes('"media_type":"image/jpeg"'));
    const [, oa] = start(one('ai.chat', { provider: 'openai', credential: 'o', model: 'gpt-5', prompt: 'x', image: 'p/cat.jpg' }), [{}]);
    assert.ok(oa.pending.effect.requests[0].body.includes(`data:image/jpeg;base64,${marker}`));
    const [, ge] = start(one('ai.chat', { provider: 'gemini', credential: 'g', model: 'gemini-2.5-flash', prompt: 'x', image: 'p/cat.jpg' }), [{}]);
    assert.ok(ge.pending.effect.requests[0].body.includes('"inline_data"'));
    const [, bad] = start(one('ai.chat', { provider: 'anthropic', credential: 'c', prompt: 'x', image: 'notes.txt' }), [{}]);
    assert.equal(bad.error, 'Step: NodeError: notes.txt is not an image');
  });

  it('Extract Text puts the text in a field, and reports errors', () => {
    const wf = one('files.extract', { path: '{{ $json.file.path }}', field: 'body' });
    const [json, s] = start(wf, [{ file: ref }]);
    assert.deepEqual(s.pending.effect, { type: 'extract', files: ['shared/123-photo.jpg'] });
    const ok = resume(wf, json, { results: [{ text: 'Hello' }] });
    assert.equal(ok.last['Step'][0].body, 'Hello');
    const bad = resume(wf, json, { results: [{ error: 'photo.jpg has no text' }] });
    assert.equal(bad.error, 'Step: NodeError: photo.jpg has no text');
    const [, missing] = start(one('files.extract', { path: '' }), [{}]);
    assert.equal(missing.error, 'Step: NodeError: file is required');
  });

  it('Add to Knowledge Base refuses empty text', () => {
    const [, s] = start(one('rag.add', { collection: 'n', text: '{{ $json.text }}' }), [{ text: '  ' }]);
    assert.equal(s.error, 'Step: NodeError: nothing to add: Text is empty (item 1)');
  });
});
