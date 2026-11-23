/**
 * Phone productivity nodes: the phone's own calendar and contacts, asking the
 * person a question, speech to text, sound and Do Not Disturb, alarms and
 * timers, and photos (camera, gallery, document scan).
 *
 * Each asks the Android host for one effect; the host does the work with the
 * phone's own apps and permissions and answers with data the node adds to its items.
 */

import { fail } from '../../errors.ts';
import { cloneObj, getKey, isObj, setKey, toNum, type Obj, type Val } from '../../value.ts';
import type { Item } from '../context.ts';
import {
  checkEffectError, itemsOf, paramNumber, paramText, paramValue, resumePassThrough, withField,
  type NodeRun, type NodeSpec, type ParamSpec,
} from './spec.ts';

const fieldParam = (fallback: string): ParamSpec =>
  ({ key: 'field', label: 'Output field', kind: 'text', default: fallback });

function checkOption(value: string, options: string[], what: string): string {
  if (!options.includes(value)) fail('NodeError', `unknown ${what} ${value}`);
  return value;
}

/** Each item with the host's per-item answer (`results[i]`) under the output field. */
function perItemResults(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const results = getKey(result, 'results');
  if (!Array.isArray(results)) return fail('NodeError', 'the phone returned no result');
  const field = paramText(run, 'field', 0);
  return [itemsOf(run).map((item, i) => {
    const copy = cloneObj(item);
    setKey(copy, field, results[i] ?? null);
    return copy;
  })];
}

/** Every item with the result's [keys] (one value, or an object of them) under the output field. */
function storeKeys(keys: string[]) {
  return (run: NodeRun, result: Obj): Item[][] => {
    checkEffectError(result);
    const value: Obj = {};
    for (const key of keys) setKey(value, key, getKey(result, key));
    return [withField(itemsOf(run), paramText(run, 'field', 0), keys.length === 1 ? getKey(value, keys[0]!) : value)];
  };
}

/** A list the host returned under [key], or an empty one. */
function listOf(result: Obj, key: string): Val[] {
  const v = getKey(result, key);
  return Array.isArray(v) ? v : [];
}

// ---------------------------------------------------------------- calendar

const CALENDAR_OPERATIONS = ['list', 'freeSlots', 'create'];

function calendarRun(run: NodeRun): { effect: Obj } {
  const operation = checkOption(paramText(run, 'operation', 0), CALENDAR_OPERATIONS, 'operation');
  if (operation === 'create') {
    const events = itemsOf(run).map((_, i) => {
      const title = paramText(run, 'title', i);
      if (title === '') fail('NodeError', 'title is empty');
      const start = paramText(run, 'start', i);
      if (start === '') fail('NodeError', 'start is empty');
      return {
        title,
        start,
        end: paramText(run, 'end', i),
        allDay: getKey(run.params, 'allDay') === true,
        location: paramText(run, 'location', i),
        description: paramText(run, 'description', i),
        calendar: paramText(run, 'calendar', i),
      };
    });
    return { effect: { type: 'calendar', operation, events } };
  }
  const effect: Obj = {
    type: 'calendar',
    operation,
    from: paramText(run, 'from', 0),
    to: paramText(run, 'to', 0),
    calendar: paramText(run, 'calendar', 0),
  };
  if (operation === 'freeSlots') {
    const minutes = Math.trunc(paramNumber(run, 'minutes', 0));
    effect['minutes'] = minutes >= 1 ? minutes : 1;
    effect['dayStart'] = clockTime(paramText(run, 'dayStart', 0), 'day starts at');
    effect['dayEnd'] = clockTime(paramText(run, 'dayEnd', 0), 'day ends at');
  }
  return { effect };
}

function calendarResume(run: NodeRun, result: Obj): Item[][] {
  const operation = paramText(run, 'operation', 0);
  if (operation === 'create') return perItemResults(run, result);
  checkEffectError(result);
  const list = listOf(result, operation === 'freeSlots' ? 'slots' : 'events');
  return [withField(itemsOf(run), paramText(run, 'field', 0), list)];
}

// ---------------------------------------------------------------- times and days

/** `7:05` → `07:05`; fails unless it is a 24-hour time. */
function clockTime(text: string, what: string): string {
  const m = /^(\d{1,2}):(\d{2})$/.exec(text.trim());
  const hour = m === null ? -1 : Number(m[1]);
  const minute = m === null ? -1 : Number(m[2]);
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) fail('NodeError', `${what} must be a time like 07:30`);
  return `${hour < 10 ? '0' : ''}${hour}:${minute < 10 ? '0' : ''}${minute}`;
}

const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

/** `Mon, wed` → `['mon', 'wed']`, in the order given, without repeats. */
function days(text: string): string[] {
  const out: string[] = [];
  for (const part of text.split(',')) {
    const day = part.trim();
    if (day === '') continue;
    const short = day.toLowerCase().slice(0, 3);
    if (!DAYS.includes(short)) fail('NodeError', `unknown day ${day}`);
    if (!out.includes(short)) out.push(short);
  }
  return out;
}

// ---------------------------------------------------------------- ask

function askRun(run: NodeRun): { effect: Obj } {
  const question = paramText(run, 'question', 0);
  if (question === '') fail('NodeError', 'question is empty');
  const buttons = paramText(run, 'buttons', 0).split(',').map((b) => b.trim()).filter((b) => b !== '');
  const reply = getKey(run.params, 'reply') === true;
  if (buttons.length === 0 && !reply) fail('NodeError', 'add a button, or let the person type an answer');
  if (buttons.length > 3) fail('NodeError', 'a notification shows at most 3 buttons');
  const minutes = toNum(paramValue(run, 'timeout', 0));
  return {
    effect: {
      type: 'ask',
      title: paramText(run, 'title', 0),
      question,
      buttons,
      reply,
      timeoutMs: (minutes > 0 ? minutes : 1) * 60000,
    },
  };
}

function askResume(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const text = (key: string): string => {
    const v = getKey(result, key);
    return typeof v === 'string' ? v : '';
  };
  const answer: Obj = { button: text('button'), text: text('text'), timedOut: getKey(result, 'timedOut') === true };
  return [withField(itemsOf(run), paramText(run, 'field', 0), answer)];
}

// ---------------------------------------------------------------- sound

const SOUND_MODES = ['silent', 'vibrate', 'normal', 'dndOn', 'dndPriority', 'dndAlarms', 'dndOff', 'read'];

// ---------------------------------------------------------------- contacts

const CONTACT_OPERATIONS = ['find', 'add'];

function contactsRun(run: NodeRun): { effect: Obj } {
  const operation = checkOption(paramText(run, 'operation', 0), CONTACT_OPERATIONS, 'operation');
  if (operation === 'add') {
    const contacts = itemsOf(run).map((_, i) => {
      const name = paramText(run, 'name', i);
      if (name === '') fail('NodeError', 'name is empty');
      return { name, phone: paramText(run, 'phone', i), email: paramText(run, 'email', i) };
    });
    return { effect: { type: 'contacts', operation, contacts } };
  }
  const queries = itemsOf(run).map((_, i) => {
    const query = paramText(run, 'query', i);
    if (query === '') fail('NodeError', 'search for a name or a number');
    return query;
  });
  const limit = Math.trunc(paramNumber(run, 'limit', 0));
  return { effect: { type: 'contacts', operation, queries, limit: limit >= 1 ? limit : 1 } };
}

// ---------------------------------------------------------------- clock

const CLOCK_OPERATIONS = ['alarm', 'timer', 'showAlarms'];

function clockRun(run: NodeRun): { effect: Obj } {
  const operation = checkOption(paramText(run, 'operation', 0), CLOCK_OPERATIONS, 'operation');
  const label = paramText(run, 'label', 0);
  if (operation === 'alarm') {
    const [hour, minute] = clockTime(paramText(run, 'time', 0), 'time').split(':').map(Number);
    return { effect: { type: 'clock', operation, hour: hour ?? 0, minute: minute ?? 0, days: days(paramText(run, 'days', 0)), label } };
  }
  if (operation === 'timer') {
    const seconds = Math.trunc(paramNumber(run, 'seconds', 0));
    if (seconds < 1) fail('NodeError', 'the timer needs at least 1 second');
    return { effect: { type: 'clock', operation, seconds, label } };
  }
  return { effect: { type: 'clock', operation } };
}

// ---------------------------------------------------------------- photos

const PHOTO_SOURCES = ['camera', 'gallery', 'scan'];

function photoRun(run: NodeRun): { effect: Obj } {
  const source = checkOption(paramText(run, 'source', 0), PHOTO_SOURCES, 'source');
  const pages = Math.trunc(paramNumber(run, 'pages', 0));
  return {
    effect: {
      type: 'photo',
      source,
      multiple: getKey(run.params, 'multiple') === true,
      pages: pages < 1 ? 1 : pages > 20 ? 20 : pages,
      pdf: getKey(run.params, 'pdf') === true,
    },
  };
}

/** Every item with `file` (the first photo or page), `files` (all of them) and, for a scan, `pdf`. */
function photoResume(run: NodeRun, result: Obj): Item[][] {
  checkEffectError(result);
  const files = listOf(result, 'files').filter(isObj);
  if (files.length === 0) fail('NodeError', getKey(result, 'cancelled') === true ? 'cancelled: no photo was taken' : 'the phone returned no photo');
  let items = withField(itemsOf(run), 'file', files[0] ?? null);
  items = withField(items, 'files', files);
  const pdf = getKey(result, 'pdf');
  if (isObj(pdf)) items = withField(items, 'pdf', pdf);
  return [items];
}

export const phoneNodes: NodeSpec[] = [
  {
    type: 'android.calendar',
    label: 'Phone Calendar',
    group: 'android',
    description: 'Lists events, finds free time, or adds events in the phone’s own calendars (any account, no sign-in).',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'list', options: CALENDAR_OPERATIONS },
      { key: 'from', label: 'From', kind: 'text', default: '', hint: 'empty = start of today; a date and time, e.g. {{ $now }}' },
      { key: 'to', label: 'To', kind: 'text', default: '', hint: 'empty = the end of that day' },
      { key: 'minutes', label: 'Shortest free time (minutes)', kind: 'number', default: 30 },
      { key: 'dayStart', label: 'Day starts at', kind: 'text', default: '08:00' },
      { key: 'dayEnd', label: 'Day ends at', kind: 'text', default: '18:00' },
      { key: 'title', label: 'Title', kind: 'text', default: '' },
      { key: 'start', label: 'Starts', kind: 'text', default: '', hint: 'a date and time, e.g. 2026-11-24T15:00' },
      { key: 'end', label: 'Ends', kind: 'text', default: '', hint: 'empty = one hour later' },
      { key: 'allDay', label: 'All day', kind: 'boolean', default: false },
      { key: 'location', label: 'Location', kind: 'text', default: '' },
      { key: 'description', label: 'Notes', kind: 'text', default: '' },
      { key: 'calendar', label: 'Calendar', kind: 'text', default: '', hint: 'part of its name; empty = all (new events: the main one)' },
      fieldParam('calendar'),
    ],
    run: calendarRun,
    resume: calendarResume,
  },
  {
    type: 'android.ask',
    label: 'Ask Me',
    group: 'android',
    description: 'Shows a notification with buttons or a reply box, and waits for your answer.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'title', label: 'Title', kind: 'text', default: 'FlowDroid asks' },
      { key: 'question', label: 'Question', kind: 'text', default: '' },
      { key: 'buttons', label: 'Buttons', kind: 'text', default: 'Yes, No', hint: 'comma separated, up to 3' },
      { key: 'reply', label: 'Let me type an answer', kind: 'boolean', default: false },
      { key: 'timeout', label: 'Wait at most (minutes)', kind: 'number', default: 60 },
      fieldParam('answer'),
    ],
    run: askRun,
    resume: askResume,
  },
  {
    type: 'android.listen',
    label: 'Speech to Text',
    group: 'android',
    description: 'Listens through the microphone and adds what you said as text.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'prompt', label: 'Prompt', kind: 'text', default: 'Speak now' },
      { key: 'language', label: 'Language', kind: 'text', default: '', hint: 'e.g. en-US; empty = the phone’s language' },
      { key: 'seconds', label: 'Listen at most (seconds)', kind: 'number', default: 30 },
      fieldParam('speech'),
    ],
    run: (run) => {
      const seconds = toNum(paramValue(run, 'seconds', 0));
      return {
        effect: {
          type: 'listen',
          prompt: paramText(run, 'prompt', 0),
          language: paramText(run, 'language', 0),
          maxMs: (seconds > 0 ? seconds : 1) * 1000,
        },
      };
    },
    resume: storeKeys(['text', 'confidence']),
  },
  {
    type: 'android.sound',
    label: 'Sound Mode',
    group: 'android',
    description: 'Sets the ringer (silent, vibrate, normal) or Do Not Disturb; adds the mode it had before, so you can restore it.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'mode', label: 'Set to', kind: 'select', default: 'silent', options: SOUND_MODES },
      fieldParam('sound'),
    ],
    run: (run) => ({ effect: { type: 'soundMode', mode: checkOption(paramText(run, 'mode', 0), SOUND_MODES, 'mode') } }),
    resume: storeKeys(['ringer', 'dnd']),
  },
  {
    type: 'android.contacts',
    label: 'Contacts',
    group: 'android',
    description: 'Finds contacts by name or number (one search per item), or adds new ones.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'find', options: CONTACT_OPERATIONS },
      { key: 'query', label: 'Name or number', kind: 'text', default: '' },
      { key: 'limit', label: 'Most results', kind: 'number', default: 5 },
      { key: 'name', label: 'Name', kind: 'text', default: '' },
      { key: 'phone', label: 'Phone number', kind: 'text', default: '' },
      { key: 'email', label: 'Email', kind: 'text', default: '' },
      fieldParam('contacts'),
    ],
    run: contactsRun,
    resume: perItemResults,
  },
  {
    type: 'android.clock',
    label: 'Alarm & Timer',
    group: 'android',
    description: 'Sets an alarm or starts a timer in the phone’s clock app (first item).',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'operation', label: 'Operation', kind: 'select', default: 'alarm', options: CLOCK_OPERATIONS },
      { key: 'time', label: 'Time', kind: 'text', default: '07:00', hint: '24-hour, e.g. 06:45' },
      { key: 'days', label: 'Repeat on', kind: 'text', default: '', hint: 'e.g. mon, tue, fri; empty = once' },
      { key: 'seconds', label: 'Timer length (seconds)', kind: 'number', default: 300 },
      { key: 'label', label: 'Label', kind: 'text', default: '' },
    ],
    run: clockRun,
    resume: resumePassThrough,
  },
  {
    type: 'android.photo',
    label: 'Photo & Scan',
    group: 'android',
    description: 'Takes a photo, picks photos from the gallery, or scans a document; adds them as files. Needs FlowDroid on screen.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'source', label: 'From', kind: 'select', default: 'camera', options: PHOTO_SOURCES },
      { key: 'multiple', label: 'Pick several', kind: 'boolean', default: false },
      { key: 'pages', label: 'Most pages', kind: 'number', default: 5 },
      { key: 'pdf', label: 'Also make a PDF', kind: 'boolean', default: true },
    ],
    run: photoRun,
    resume: photoResume,
  },
];
