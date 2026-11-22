/**
 * Trigger nodes start an execution. The host decides when they fire
 * (button, schedule, incoming HTTP request) and passes their items to
 * `startExecution`; inside a run they simply pass items on.
 */

import { credentialParam } from './integrations/api.ts';
import { passThrough, type NodeSpec, type ParamSpec } from './spec.ts';

/** A trigger the host fires; inside a run it passes its items on. */
function trigger(type: string, label: string, description: string, params: ParamSpec[] = []): NodeSpec {
  return { type, label, group: 'trigger', description, inputs: 0, outputs: ['main'], params, run: passThrough };
}

/** Phone events the Phone Event trigger can wait for. */
export const PHONE_EVENTS = [
  'powerConnected', 'powerDisconnected', 'batteryLow',
  'wifiConnected', 'wifiDisconnected', 'screenOn', 'screenOff', 'boot',
];

export const triggerNodes: NodeSpec[] = [
  {
    type: 'trigger.manual',
    label: 'Manual Trigger',
    group: 'trigger',
    description: 'Runs the workflow when you tap Run.',
    inputs: 0,
    outputs: ['main'],
    params: [],
    run: passThrough,
  },
  {
    type: 'trigger.schedule',
    label: 'Schedule Trigger',
    group: 'trigger',
    description: 'Runs on a cron schedule, or every N minutes (Android runs periodic work at most every 15 minutes).',
    inputs: 0,
    outputs: ['main'],
    params: [
      { key: 'mode', label: 'Mode', kind: 'select', default: 'interval', options: ['interval', 'cron'] },
      { key: 'minutes', label: 'Every (minutes)', kind: 'number', default: 15 },
      { key: 'cron', label: 'Cron expression', kind: 'text', default: '0 9 * * *', hint: 'minute hour day month weekday' },
    ],
    run: passThrough,
  },
  {
    type: 'trigger.webhook',
    label: 'Webhook Trigger',
    group: 'trigger',
    description: 'Runs when an HTTP request reaches the on-device server at /webhook/<path>.',
    inputs: 0,
    outputs: ['main'],
    params: [
      { key: 'path', label: 'Path', kind: 'text', default: 'my-hook' },
      { key: 'method', label: 'Method', kind: 'select', default: 'POST', options: ['GET', 'POST', 'PUT', 'DELETE', 'ANY'] },
      { ...credentialParam(['webhookAuth']), label: 'Require a key', hint: 'empty = anyone on the network can call it' },
    ],
    run: passThrough,
  },
  trigger('trigger.subworkflow', 'When Called by a Workflow', 'Runs when another workflow’s Execute Workflow node calls this one, with its items.'),
  trigger('trigger.error', 'Error Trigger', 'Runs when a workflow that names this one as its error workflow fails.'),
  trigger('trigger.sms', 'SMS Trigger', 'Runs for each SMS the phone receives (while FlowDroid runs).', [
    { key: 'from', label: 'Only from', kind: 'text', default: '', hint: 'number, or part of it; empty = anyone' },
    { key: 'contains', label: 'Only if the text contains', kind: 'text', default: '' },
  ]),
  trigger('trigger.notification', 'Notification Trigger', 'Runs when another app shows a notification (needs notification access).', [
    { key: 'app', label: 'Only from app', kind: 'text', default: '', hint: 'app name or package, e.g. whatsapp' },
    { key: 'contains', label: 'Only if the text contains', kind: 'text', default: '' },
  ]),
  trigger('trigger.phone', 'Phone Event Trigger', 'Runs when the phone is plugged in, Wi-Fi connects, the screen turns on, and more.', [
    { key: 'event', label: 'Event', kind: 'select', default: 'powerConnected', options: PHONE_EVENTS },
  ]),
  trigger('trigger.place', 'Place Trigger', 'Runs when you arrive at or leave a place (checked every minute; needs location “all the time”).', [
    { key: 'latitude', label: 'Latitude', kind: 'number', default: 0 },
    { key: 'longitude', label: 'Longitude', kind: 'number', default: 0 },
    { key: 'radius', label: 'Radius (meters)', kind: 'number', default: 200 },
    { key: 'event', label: 'When I', kind: 'select', default: 'enter', options: ['enter', 'leave'] },
  ]),
  trigger('trigger.share', 'Share Trigger', 'Runs when you share text, a link or a file to FlowDroid from another app.'),
  trigger('trigger.tile', 'Quick Tile Trigger', 'Runs when you tap the FlowDroid tile in Quick Settings.'),
  trigger('trigger.rss', 'RSS Trigger', 'Runs once for each new post in a feed.', [
    { key: 'url', label: 'Feed URL', kind: 'text', default: '' },
    { key: 'minutes', label: 'Check every (minutes)', kind: 'number', default: 15 },
  ]),
  trigger('trigger.email', 'Email Trigger (IMAP)', 'Runs once for each new email in a mailbox.', [
    credentialParam(['email']),
    { key: 'mailbox', label: 'Mailbox', kind: 'text', default: 'INBOX' },
    { key: 'minutes', label: 'Check every (minutes)', kind: 'number', default: 5 },
  ]),
];
