/**
 * Device nodes. Each one asks the Android host for an effect
 * (notification, clipboard, battery, location, …) and, where the effect
 * returns data, adds it to every item under a field.
 */

import { fail } from '../../errors.ts';
import { getKey, type Obj } from '../../value.ts';
import type { Item } from '../context.ts';
import {
  checkEffectError, itemsOf, paramNumber, paramText, resumePassThrough, withField,
  type NodeRun, type NodeSpec, type ParamSpec,
} from './spec.ts';

const SPEAK_PROVIDERS = ['phone', 'openai', 'elevenlabs'];

/** The speak effect; fields at their defaults are left out, so the plain phone voice stays `{ type, text }`. */
function speakEffect(run: NodeRun): Obj {
  const effect: Obj = { type: 'speak', text: paramText(run, 'text', 0) };
  const provider = paramText(run, 'provider', 0);
  if (provider !== '' && provider !== 'phone') {
    if (!SPEAK_PROVIDERS.includes(provider)) fail('NodeError', `unknown voice provider ${provider}`);
    const credential = paramText(run, 'credential', 0);
    if (credential === '') fail('NodeError', 'choose a credential for the cloud voice');
    effect['provider'] = provider;
    effect['credential'] = credential;
  }
  const voice = paramText(run, 'voice', 0);
  if (voice !== '') effect['voice'] = voice;
  const speed = paramNumber(run, 'speed', 0);
  if (speed > 0 && speed !== 1) effect['speed'] = Math.min(4, Math.max(0.25, speed));
  const style = paramText(run, 'style', 0);
  if (style !== '') effect['style'] = style;
  return effect;
}

const fieldParam = (fallback: string): ParamSpec =>
  ({ key: 'field', label: 'Output field', kind: 'text', default: fallback });

/** Resume for read effects: the result's `keys` become an object stored on each item. */
function storeResult(keys: string[]) {
  return (run: NodeRun, result: Obj): Item[][] => {
    checkEffectError(result);
    const value: Obj = {};
    for (const key of keys) value[key] = getKey(result, key);
    return [withField(itemsOf(run), paramText(run, 'field', 0), keys.length === 1 ? (value[keys[0]!] ?? null) : value)];
  };
}

export const androidNodes: NodeSpec[] = [
  {
    type: 'android.notify',
    label: 'Show Notification',
    group: 'android',
    description: 'Posts one notification per item.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'title', label: 'Title', kind: 'text', default: 'FlowDroid' },
      { key: 'body', label: 'Message', kind: 'text', default: '' },
    ],
    run: (run) => ({
      effect: {
        type: 'notify',
        notifications: itemsOf(run).map((_, i) => ({ title: paramText(run, 'title', i), body: paramText(run, 'body', i) })),
      },
    }),
    resume: resumePassThrough,
  },
  {
    type: 'android.sms',
    label: 'Send SMS',
    group: 'android',
    description: 'Sends a text message per item from this phone (carrier rates apply).',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'to', label: 'To (phone number)', kind: 'text', default: '' },
      { key: 'text', label: 'Message', kind: 'text', default: '' },
    ],
    run: (run) => ({
      effect: {
        type: 'sms',
        messages: itemsOf(run).map((_, i) => {
          const to = paramText(run, 'to', i);
          if (to === '') fail('NodeError', 'phone number is required');
          return { to, text: paramText(run, 'text', i) };
        }),
      },
    }),
    resume: resumePassThrough,
  },
  {
    type: 'android.speak',
    label: 'Speak Text',
    group: 'android',
    description: 'Reads text aloud (first item) with a phone voice, or a natural cloud voice from OpenAI or ElevenLabs.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'text', label: 'Text', kind: 'text', default: '' },
      { key: 'provider', label: 'Voice from', kind: 'select', default: 'phone', options: SPEAK_PROVIDERS },
      { key: 'credential', label: 'Credential', kind: 'credential', default: '', options: ['openai', 'elevenlabs'], hint: 'not needed for phone voices' },
      { key: 'voice', label: 'Voice', kind: 'text', default: '', hint: 'empty = default' },
      { key: 'speed', label: 'Speed', kind: 'number', default: 1, hint: '0.5 to 2' },
      { key: 'style', label: 'Speaking style', kind: 'text', default: '', hint: 'OpenAI only, e.g. calm and warm' },
    ],
    run: (run) => ({ effect: speakEffect(run) }),
    resume: resumePassThrough,
  },
  {
    type: 'android.vibrate',
    label: 'Vibrate',
    group: 'android',
    description: 'Vibrates the device.',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'ms', label: 'Duration (ms)', kind: 'number', default: 500 }],
    run: (run) => {
      const ms = paramNumber(run, 'ms', 0);
      return { effect: { type: 'vibrate', ms: ms > 0 ? ms : 0 } };
    },
    resume: resumePassThrough,
  },
  {
    type: 'android.openUrl',
    label: 'Open URL',
    group: 'android',
    description: 'Opens a link in the browser or the app that handles it (first item).',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'url', label: 'URL', kind: 'text', default: 'https://' }],
    run: (run) => ({ effect: { type: 'openUrl', url: paramText(run, 'url', 0) } }),
    resume: resumePassThrough,
  },
  {
    type: 'android.clipboardWrite',
    label: 'Copy to Clipboard',
    group: 'android',
    description: 'Copies text to the clipboard (first item).',
    inputs: 1,
    outputs: ['main'],
    params: [{ key: 'text', label: 'Text', kind: 'text', default: '' }],
    run: (run) => ({ effect: { type: 'clipboardWrite', text: paramText(run, 'text', 0) } }),
    resume: resumePassThrough,
  },
  {
    type: 'android.clipboardRead',
    label: 'Read Clipboard',
    group: 'android',
    description: 'Adds the clipboard text to every item.',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('clipboard')],
    run: () => ({ effect: { type: 'clipboardRead' } }),
    resume: storeResult(['text']),
  },
  {
    type: 'android.battery',
    label: 'Battery Status',
    group: 'android',
    description: 'Adds the battery level (0-100) and charging state to every item.',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('battery')],
    run: () => ({ effect: { type: 'battery' } }),
    resume: storeResult(['level', 'charging']),
  },
  {
    type: 'android.location',
    label: 'Get Location',
    group: 'android',
    description: 'Adds the current GPS position to every item.',
    inputs: 1,
    outputs: ['main'],
    params: [fieldParam('location')],
    run: () => ({ effect: { type: 'location' } }),
    resume: storeResult(['latitude', 'longitude', 'accuracy']),
  },
];
