/** Telegram and Discord: send messages, and a Telegram trigger the host polls. */

import { fail } from '../../../errors.ts';
import { getKey, isObj, stringify, type Obj, type Val } from '../../../value.ts';
import { filePath, isImagePath } from '../file_refs.ts';
import type { Item } from '../../context.ts';
import { paramText, passThrough, type NodeRun, type NodeSpec } from '../spec.ts';
import { apiRequest, apiResume, asItems, credentialParam, enc, perItem } from './api.ts';

function required(run: NodeRun, key: string, index: number, label: string): string {
  const v = paramText(run, key, index);
  if (v === '') fail('NodeError', `${label} is required`);
  return v;
}

function telegramSend(run: NodeRun, index: number): Obj {
  const file = filePath(run, 'file', index);
  if (file !== '') {
    // A photo or document, with the text as its caption.
    const photo = isImagePath(file);
    const parts: Val[] = [
      { name: 'chat_id', value: required(run, 'chatId', index, 'chat ID') },
      { name: photo ? 'photo' : 'document', file },
    ];
    const caption = paramText(run, 'text', index);
    if (caption !== '') parts.push({ name: 'caption', value: caption });
    const mode = paramText(run, 'parseMode', index);
    if (mode !== 'none' && mode !== '' && caption !== '') parts.push({ name: 'parse_mode', value: mode });
    const request = apiRequest(run, {
      method: 'POST',
      url: `https://api.telegram.org/bot{cred:botToken}/${photo ? 'sendPhoto' : 'sendDocument'}`,
    });
    request['multipart'] = parts;
    return request;
  }
  const body: Obj = {
    chat_id: required(run, 'chatId', index, 'chat ID'),
    text: required(run, 'text', index, 'text'),
  };
  const mode = paramText(run, 'parseMode', index);
  if (mode !== 'none' && mode !== '') body['parse_mode'] = mode;
  return apiRequest(run, {
    method: 'POST',
    url: 'https://api.telegram.org/bot{cred:botToken}/sendMessage',
    body,
  });
}

function telegramResult(body: Val): Item[] {
  if (isObj(body) && getKey(body, 'ok') === false) {
    const description = getKey(body, 'description');
    fail('NodeError', `Telegram: ${typeof description === 'string' ? description : 'request failed'}`);
  }
  return asItems(isObj(body) ? getKey(body, 'result') : body);
}

function discordSend(run: NodeRun, index: number): Obj {
  const file = filePath(run, 'file', index);
  const content = file === '' ? required(run, 'content', index, 'message') : paramText(run, 'content', index);
  const bot = paramText(run, 'mode', index) === 'bot';
  const body: Obj = { content };
  if (!bot) {
    const username = paramText(run, 'username', index);
    if (username !== '') body['username'] = username;
  }
  const call = bot
    ? {
        method: 'POST',
        url: `https://discord.com/api/v10/channels/${enc(required(run, 'channelId', index, 'channel ID'))}/messages`,
        headers: { Authorization: 'Bot {cred:botToken}' },
      }
    : { method: 'POST', url: '{cred:url}?wait=true' };
  if (file === '') return apiRequest(run, { ...call, body });
  // The message rides along as JSON next to the attached file.
  const request = apiRequest(run, call);
  request['multipart'] = [
    { name: 'payload_json', value: stringify(body) },
    { name: 'files[0]', file },
  ];
  return request;
}

export const messagingNodes: NodeSpec[] = [
  {
    type: 'trigger.telegram',
    label: 'Telegram Trigger',
    group: 'trigger',
    description: 'Runs for each message your Telegram bot receives (checked while FlowDroid runs).',
    inputs: 0,
    outputs: ['main'],
    params: [
      credentialParam(['telegram']),
      { key: 'chatId', label: 'Only from chat ID', kind: 'text', default: '', hint: 'empty = any chat' },
    ],
    run: passThrough,
  },
  {
    type: 'telegram.send',
    label: 'Telegram',
    group: 'communication',
    description: 'Sends a message from your Telegram bot to a chat.',
    inputs: 1,
    outputs: ['main'],
    params: [
      credentialParam(['telegram']),
      { key: 'chatId', label: 'Chat ID', kind: 'text', default: '{{ $json.chat.id }}' },
      { key: 'text', label: 'Text', kind: 'text', default: '' },
      { key: 'parseMode', label: 'Formatting', kind: 'select', default: 'none', options: ['none', 'MarkdownV2', 'HTML'] },
      { key: 'file', label: 'Photo or file', kind: 'text', default: '', hint: 'e.g. {{ $json.file.path }}; the text becomes its caption' },
    ],
    run: (run) => perItem(run, (i) => telegramSend(run, i)),
    resume: apiResume('Telegram', telegramResult),
  },
  {
    type: 'discord.send',
    label: 'Discord',
    group: 'communication',
    description: 'Posts a message to a Discord channel through a webhook or a bot.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'mode', label: 'Send with', kind: 'select', default: 'webhook', options: ['webhook', 'bot'] },
      credentialParam(['discordWebhook', 'discordBot']),
      { key: 'channelId', label: 'Channel ID (bot)', kind: 'text', default: '' },
      { key: 'content', label: 'Message', kind: 'text', default: '' },
      { key: 'username', label: 'Name shown (webhook)', kind: 'text', default: '' },
      { key: 'file', label: 'Attach a file', kind: 'text', default: '', hint: 'e.g. {{ $json.file.path }}' },
    ],
    run: (run) => perItem(run, (i) => discordSend(run, i)),
    resume: apiResume('Discord', (body) => asItems(body)),
  },
];
