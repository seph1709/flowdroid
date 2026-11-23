import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { resumeExecution, startExecution } from '../src/api.ts';
import { workflow } from './fixtures.ts';

const NOW = Date.UTC(2026, 10, 22, 9);

type State = {
  status: string;
  error: string | null;
  pending: { effect: unknown } | null;
  last: Record<string, Record<string, unknown>[]>;
};

const single = (type: string, params: object): string =>
  workflow([{ id: 'start', name: 'Start', type: 'trigger.manual' }, { id: 'n', name: 'Step', type, params }], [{ from: 'start', to: 'n' }]);

const start = (wf: string, items: unknown[] = [{}]): [string, State] => {
  const json = startExecution(wf, 'start', JSON.stringify(items), NOW);
  return [json, JSON.parse(json) as State];
};

const resume = (wf: string, state: string, result: unknown): State =>
  JSON.parse(resumeExecution(wf, state, JSON.stringify(result), NOW + 1)) as State;

const err = (type: string, params: object, items: unknown[] = [{}]) => start(single(type, params), items)[1].error;

describe('Phone Calendar', () => {
  it('lists events and adds them to every item', () => {
    const wf = single('android.calendar', { from: '{{ $json.day }}', calendar: 'Work' });
    const [json, s] = start(wf, [{ day: '2026-11-24' }, { day: 'x' }]);
    assert.deepEqual(s.pending!.effect, { type: 'calendar', operation: 'list', from: '2026-11-24', to: '', calendar: 'Work' });
    const events = [{ title: 'Standup', start: '2026-11-24T09:00:00+08:00' }];
    const done = resume(wf, json, { events });
    assert.deepEqual(done.last['Step'], [{ day: '2026-11-24', calendar: events }, { day: 'x', calendar: events }]);
    assert.deepEqual(resume(wf, json, {}).last['Step']![0], { day: '2026-11-24', calendar: [] });
    assert.equal(resume(wf, json, { error: 'calendar access denied' }).error, 'Step: NodeError: calendar access denied');
  });

  it('finds free time within working hours', () => {
    const wf = single('android.calendar', { operation: 'freeSlots', minutes: 45.9, dayStart: '9:00', dayEnd: '17:30', field: 'free' });
    const [json, s] = start(wf);
    assert.deepEqual(s.pending!.effect, {
      type: 'calendar', operation: 'freeSlots', from: '', to: '', calendar: '', minutes: 45, dayStart: '09:00', dayEnd: '17:30',
    });
    const slots = [{ start: 'a', end: 'b', minutes: 60 }];
    assert.deepEqual(resume(wf, json, { slots }).last['Step'], [{ free: slots }]);
    assert.equal(err('android.calendar', { operation: 'freeSlots', dayStart: '25:00' }), 'Step: NodeError: day starts at must be a time like 07:30');
  });

  it('creates one event per item', () => {
    const wf = single('android.calendar', { operation: 'create', title: '{{ $json.t }}', start: '2026-11-24T15:00', allDay: true, field: 'event' });
    const [json, s] = start(wf, [{ t: 'Dentist' }]);
    assert.deepEqual(s.pending!.effect, {
      type: 'calendar', operation: 'create',
      events: [{ title: 'Dentist', start: '2026-11-24T15:00', end: '', allDay: true, location: '', description: '', calendar: '' }],
    });
    assert.deepEqual(resume(wf, json, { results: [{ id: '42' }] }).last['Step'], [{ t: 'Dentist', event: { id: '42' } }]);
    assert.equal(resume(wf, json, {}).error, 'Step: NodeError: the phone returned no result');
    assert.equal(err('android.calendar', { operation: 'create', start: 'x' }), 'Step: NodeError: title is empty');
    assert.equal(err('android.calendar', { operation: 'create', title: 'x' }), 'Step: NodeError: start is empty');
    assert.equal(err('android.calendar', { operation: 'delete' }), 'Step: NodeError: unknown operation delete');
  });
});

describe('Ask Me', () => {
  it('asks with buttons and adds the answer', () => {
    const wf = single('android.ask', { question: 'Send {{ $json.n }}?', buttons: ' Send , ,Skip', reply: true, timeout: 0.5 });
    const [json, s] = start(wf, [{ n: 'report' }]);
    assert.deepEqual(s.pending!.effect, {
      type: 'ask', title: 'FlowDroid asks', question: 'Send report?', buttons: ['Send', 'Skip'], reply: true, timeoutMs: 30000,
    });
    assert.deepEqual(resume(wf, json, { button: 'Send', text: 'ok' }).last['Step'], [
      { n: 'report', answer: { button: 'Send', text: 'ok', timedOut: false } },
    ]);
    assert.deepEqual(resume(wf, json, { timedOut: true }).last['Step']![0]!['answer'], { button: '', text: '', timedOut: true });
  });

  it('checks its question and buttons', () => {
    assert.equal(err('android.ask', { question: '' }), 'Step: NodeError: question is empty');
    assert.equal(err('android.ask', { question: 'q', buttons: ' , ' }), 'Step: NodeError: add a button, or let the person type an answer');
    assert.equal(err('android.ask', { question: 'q', buttons: 'a,b,c,d' }), 'Step: NodeError: a notification shows at most 3 buttons');
  });
});

describe('Speech, sound, contacts, clock, photos', () => {
  it('listens and stores the text', () => {
    const wf = single('android.listen', { language: 'en-US', seconds: 0 });
    const [json, s] = start(wf);
    assert.deepEqual(s.pending!.effect, { type: 'listen', prompt: 'Speak now', language: 'en-US', maxMs: 1000 });
    assert.deepEqual(resume(wf, json, { text: 'buy milk', confidence: 0.9 }).last['Step'], [{ speech: { text: 'buy milk', confidence: 0.9 } }]);
  });

  it('sets the sound mode and keeps the one before', () => {
    const wf = single('android.sound', { mode: 'dndOn' });
    const [json, s] = start(wf);
    assert.deepEqual(s.pending!.effect, { type: 'soundMode', mode: 'dndOn' });
    assert.deepEqual(resume(wf, json, { ringer: 'normal', dnd: 'off' }).last['Step'], [{ sound: { ringer: 'normal', dnd: 'off' } }]);
    assert.equal(err('android.sound', { mode: 'loud' }), 'Step: NodeError: unknown mode loud');
  });

  it('finds and adds contacts per item', () => {
    const wf = single('android.contacts', { query: '{{ $json.from }}', limit: 0 });
    const [json, s] = start(wf, [{ from: '+100' }, { from: 'Ann' }]);
    assert.deepEqual(s.pending!.effect, { type: 'contacts', operation: 'find', queries: ['+100', 'Ann'], limit: 1 });
    const ann = [{ name: 'Ann', phones: ['+100'] }];
    assert.deepEqual(resume(wf, json, { results: [ann, []] }).last['Step'], [{ from: '+100', contacts: ann }, { from: 'Ann', contacts: [] }]);
    const add = single('android.contacts', { operation: 'add', name: 'Bo', phone: '1' });
    assert.deepEqual(start(add)[1].pending!.effect, { type: 'contacts', operation: 'add', contacts: [{ name: 'Bo', phone: '1', email: '' }] });
    assert.equal(err('android.contacts', {}), 'Step: NodeError: search for a name or a number');
    assert.equal(err('android.contacts', { operation: 'add' }), 'Step: NodeError: name is empty');
  });

  it('sets alarms and timers', () => {
    const alarm = single('android.clock', { time: ' 6:05 ', days: 'Monday, fri, mon', label: 'Gym' });
    const [json, s] = start(alarm, [{ a: 1 }]);
    assert.deepEqual(s.pending!.effect, { type: 'clock', operation: 'alarm', hour: 6, minute: 5, days: ['mon', 'fri'], label: 'Gym' });
    assert.deepEqual(resume(alarm, json, {}).last['Step'], [{ a: 1 }]);
    assert.deepEqual(start(single('android.clock', { operation: 'timer', seconds: 90.7 }))[1].pending!.effect, {
      type: 'clock', operation: 'timer', seconds: 90, label: '',
    });
    assert.deepEqual(start(single('android.clock', { operation: 'showAlarms' }))[1].pending!.effect, { type: 'clock', operation: 'showAlarms' });
    assert.equal(err('android.clock', { time: '7am' }), 'Step: NodeError: time must be a time like 07:30');
    assert.equal(err('android.clock', { days: 'mon, funday' }), 'Step: NodeError: unknown day funday');
    assert.equal(err('android.clock', { operation: 'timer', seconds: 0 }), 'Step: NodeError: the timer needs at least 1 second');
  });

  it('adds photos and scans as files', () => {
    const wf = single('android.photo', { source: 'scan', pages: 50 });
    const [json, s] = start(wf, [{ a: 1 }]);
    assert.deepEqual(s.pending!.effect, { type: 'photo', source: 'scan', multiple: false, pages: 20, pdf: true });
    const page = { path: 'scans/p1.jpg', name: 'p1.jpg', mimeType: 'image/jpeg', size: 9 };
    const pdf = { path: 'scans/scan.pdf', name: 'scan.pdf', mimeType: 'application/pdf', size: 20 };
    assert.deepEqual(resume(wf, json, { files: [page], pdf }).last['Step'], [{ a: 1, file: page, files: [page], pdf }]);
    assert.equal(resume(wf, json, { files: [], cancelled: true }).error, 'Step: NodeError: cancelled: no photo was taken');
    assert.equal(resume(wf, json, {}).error, 'Step: NodeError: the phone returned no photo');
    assert.equal(err('android.photo', { source: 'video' }), 'Step: NodeError: unknown source video');
  });

  it('runs a browser script per item and stores what it found', () => {
    const wf = single('browser.run', { url: 'https://shop.example/{{ $json.id }}', steps: 'extract price .price\nscreenshot', timeout: 0 });
    const [json, s] = start(wf, [{ id: 1 }, { id: 2 }]);
    assert.deepEqual(s.pending!.effect, {
      type: 'browser',
      runs: [
        { url: 'https://shop.example/1', steps: 'extract price .price\nscreenshot' },
        { url: 'https://shop.example/2', steps: 'extract price .price\nscreenshot' },
      ],
      visible: false,
      fast: true,
      timeoutMs: 1000,
    });
    const page = (price: string) => ({ url: 'u', title: 't', data: { price }, screenshots: [] });
    assert.deepEqual(resume(wf, json, { results: [page('9'), page('12')] }).last['Step'], [
      { id: 1, browser: page('9') },
      { id: 2, browser: page('12') },
    ]);
    assert.equal(resume(wf, json, { results: [{ error: 'no element matches .price' }] }).error, 'Step: NodeError: Browser: no element matches .price');
    assert.equal(resume(wf, json, { results: [page('9')] }).error, 'Step: NodeError: the browser returned no result');
    assert.equal(err('browser.run', { url: 'shop.example' }), 'Step: NodeError: the URL must start with http:// or https://');
  });

  it('a calendar event trigger passes its event on', () => {
    const wf = workflow([{ id: 't', name: 'Event', type: 'trigger.calendar', params: { minutes: 10 } }], []);
    const s = JSON.parse(startExecution(wf, 't', JSON.stringify([{ title: 'Standup' }]), NOW)) as State;
    assert.deepEqual(s.last['Event'], [{ title: 'Standup' }]);
  });
});
