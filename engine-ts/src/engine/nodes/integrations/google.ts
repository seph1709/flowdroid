/** Google Sheets, Gmail and Calendar, through a Google account signed in on the phone. */

import { fail } from '../../../errors.ts';
import { getKey, isObj, ordered, setKey, stringify, toStr, type Obj, type Val } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, type NodeRun, type NodeSpec } from '../spec.ts';
import { apiEffect, apiRequest, apiResume, asItems, base64Standard, base64Url, credentialParam, enc, perItem } from './api.ts';
import { filePath, mimeFromPath } from '../file_refs.ts';

const SHEETS = 'https://sheets.googleapis.com/v4/spreadsheets';
const AUTH = { Authorization: 'Bearer {cred:accessToken}' };

function required(run: NodeRun, key: string, index: number, label: string): string {
  const v = paramText(run, key, index);
  if (v === '') fail('NodeError', `${label} is required`);
  return v;
}

/** One sheet row from an item's value: lists as they are, objects by their values in order. */
function rowOf(v: Val): Val[] {
  if (Array.isArray(v)) return v;
  if (isObj(v)) return ordered(v).map(([, value]) => value);
  return [v];
}

function sheets(run: NodeRun): { effect: Obj } {
  const id = required(run, 'spreadsheetId', 0, 'spreadsheet ID');
  const range = required(run, 'range', 0, 'range');
  const base = `${SHEETS}/${enc(id)}/values/${enc(range)}`;
  if (paramText(run, 'operation', 0) === 'append') {
    const values = itemsOf(run).map((_, i) => rowOf(paramValue(run, 'values', i)));
    return apiEffect([
      apiRequest(run, {
        method: 'POST',
        url: `${base}:append?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS`,
        headers: AUTH,
        body: { values },
      }),
    ]);
  }
  return apiEffect([apiRequest(run, { method: 'GET', url: base, headers: AUTH })]);
}

/** Read results as items keyed by the header row; append results as one summary item. */
function sheetItems(body: Val, _index: number, run: NodeRun): Item[] {
  if (paramText(run, 'operation', 0) === 'append') return asItems(isObj(body) ? getKey(body, 'updates') : body);
  const rows = isObj(body) ? getKey(body, 'values') : null;
  if (!Array.isArray(rows) || rows.length === 0) return [];
  const header = Array.isArray(rows[0]) ? rows[0].map((h) => toStr(h)) : [];
  return rows.slice(1).map((row): Item => {
    const item: Item = {};
    header.forEach((name, i) => setKey(item, name, Array.isArray(row) ? (row[i] ?? null) : null));
    return item;
  });
}

/** RFC 2047 encoding for a header value that is not plain ASCII. */
function headerText(text: string): string {
  return /^[\x20-\x7e]*$/.test(text) ? text : `=?UTF-8?B?${base64Standard(text)}?=`;
}

function gmail(run: NodeRun, index: number): Obj {
  const to = required(run, 'to', index, 'recipient');
  const message = [
    `To: ${headerText(to)}`,
    `Subject: ${headerText(paramText(run, 'subject', index))}`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    '',
    paramText(run, 'body', index),
  ].join('\r\n');
  return apiRequest(run, {
    method: 'POST',
    url: 'https://gmail.googleapis.com/gmail/v1/users/me/messages/send',
    headers: AUTH,
    body: { raw: base64Url(message) },
  });
}

function calendar(run: NodeRun, index: number): Obj {
  const calendarId = paramText(run, 'calendarId', index) || 'primary';
  const event: Obj = {
    summary: required(run, 'summary', index, 'title'),
    start: { dateTime: required(run, 'start', index, 'start time') },
    end: { dateTime: required(run, 'end', index, 'end time') },
  };
  const description = paramText(run, 'description', index);
  if (description !== '') event['description'] = description;
  return apiRequest(run, {
    method: 'POST',
    url: `https://www.googleapis.com/calendar/v3/calendars/${enc(calendarId)}/events`,
    headers: AUTH,
    body: event,
  });
}

const google = credentialParam(['google']);

const DRIVE = 'https://www.googleapis.com/drive/v3/files';
const DRIVE_UPLOAD = 'https://www.googleapis.com/upload/drive/v3/files';
const BOUNDARY = 'flowdroid-part';
const DRIVE_OPERATIONS = ['list', 'upload', 'download'];

function drive(run: NodeRun, index: number): Obj {
  const operation = paramText(run, 'operation', 0);
  switch (operation) {
    case 'list': {
      const query = paramText(run, 'query', index);
      const parts = ['pageSize=100', `fields=${enc('files(id,name,mimeType,modifiedTime,size)')}`];
      if (query !== '') parts.push(`q=${enc(query)}`);
      return apiRequest(run, { method: 'GET', url: `${DRIVE}?${parts.join('&')}`, headers: { ...AUTH } });
    }
    case 'upload': {
      const file = filePath(run, 'file', index);
      const name = paramText(run, 'name', index);
      const metadata: Obj = { name: file !== '' && name === '' ? (file.split('/').pop() ?? file) : required(run, 'name', index, 'file name') };
      const folder = paramText(run, 'folderId', index);
      if (folder !== '') metadata['parents'] = [folder];
      const mime = paramText(run, 'mimeType', index);
      if (file !== '') {
        // The host builds the multipart body from the metadata and the file's bytes.
        const request = apiRequest(run, {
          method: 'POST',
          url: `${DRIVE_UPLOAD}?uploadType=multipart&fields=${enc('id,name,mimeType')}`,
          headers: { ...AUTH },
        });
        request['related'] = { metadata, file, mimeType: mime === '' || mime === 'text/plain' ? mimeFromPath(file) : mime };
        return request;
      }
      const body = [
        `--${BOUNDARY}`,
        'Content-Type: application/json; charset=UTF-8',
        '',
        stringify(metadata),
        `--${BOUNDARY}`,
        `Content-Type: ${mime === '' ? 'text/plain' : mime}`,
        '',
        paramText(run, 'content', index),
        `--${BOUNDARY}--`,
      ].join('\r\n');
      return apiRequest(run, {
        method: 'POST',
        url: `${DRIVE_UPLOAD}?uploadType=multipart&fields=${enc('id,name,mimeType')}`,
        headers: { ...AUTH, 'Content-Type': `multipart/related; boundary=${BOUNDARY}` },
        body,
      });
    }
    case 'download': {
      const id = required(run, 'fileId', index, 'file ID');
      const request = apiRequest(run, { method: 'GET', url: `${DRIVE}/${enc(id)}?alt=media`, headers: { ...AUTH } });
      if (paramText(run, 'downloadAs', 0) === 'file') request['saveAs'] = 'file';
      return request;
    }
    default:
      return fail('NodeError', `unknown operation ${operation}`);
  }
}

function driveItems(body: Val, index: number, run: NodeRun): Item[] {
  switch (paramText(run, 'operation', 0)) {
    case 'list': {
      const files = isObj(body) ? getKey(body, 'files') : null;
      return Array.isArray(files) ? files.filter(isObj) : [];
    }
    case 'download':
      return paramText(run, 'downloadAs', 0) === 'file'
        ? [{ fileId: paramText(run, 'fileId', index), file: isObj(body) ? body : null }]
        : [{ fileId: paramText(run, 'fileId', index), content: body }];
    default:
      return asItems(body);
  }
}

export const googleNodes: NodeSpec[] = [
  {
    type: 'google.sheets',
    label: 'Google Sheets',
    group: 'productivity',
    description: 'Reads rows from a sheet, or appends one row per item.',
    inputs: 1,
    outputs: ['main'],
    params: [
      google,
      { key: 'operation', label: 'Operation', kind: 'select', default: 'read', options: ['read', 'append'] },
      { key: 'spreadsheetId', label: 'Spreadsheet ID', kind: 'text', default: '', hint: 'from the sheet’s URL' },
      { key: 'range', label: 'Sheet or range', kind: 'text', default: 'Sheet1' },
      { key: 'values', label: 'Row values (append)', kind: 'json', default: '{{ $json }}' },
    ],
    run: sheets,
    resume: apiResume('Google Sheets', sheetItems),
  },
  {
    type: 'google.gmail',
    label: 'Gmail',
    group: 'productivity',
    description: 'Sends an email from your Gmail account, one per item.',
    inputs: 1,
    outputs: ['main'],
    params: [
      google,
      { key: 'to', label: 'To', kind: 'text', default: '' },
      { key: 'subject', label: 'Subject', kind: 'text', default: '' },
      { key: 'body', label: 'Message', kind: 'text', default: '' },
    ],
    run: (run) => perItem(run, (i) => gmail(run, i)),
    resume: apiResume('Gmail', (body) => asItems(body)),
  },
  {
    type: 'google.calendar',
    label: 'Google Calendar',
    group: 'productivity',
    description: 'Creates a calendar event per item.',
    inputs: 1,
    outputs: ['main'],
    params: [
      google,
      { key: 'calendarId', label: 'Calendar', kind: 'text', default: 'primary' },
      { key: 'summary', label: 'Title', kind: 'text', default: '' },
      { key: 'start', label: 'Starts', kind: 'text', default: '', hint: '2026-11-22T09:00:00+08:00' },
      { key: 'end', label: 'Ends', kind: 'text', default: '' },
      { key: 'description', label: 'Description', kind: 'text', default: '' },
    ],
    run: (run) => perItem(run, (i) => calendar(run, i)),
    resume: apiResume('Google Calendar', (body) => asItems(body)),
  },
  {
    type: 'google.drive',
    label: 'Google Drive',
    group: 'productivity',
    description: 'Lists files, uploads a file per item (any type, or text), or downloads one as text or a file.',
    inputs: 1,
    outputs: ['main'],
    params: [
      google,
      { key: 'operation', label: 'Operation', kind: 'select', default: 'list', options: DRIVE_OPERATIONS },
      { key: 'query', label: 'Search (list)', kind: 'text', default: '', hint: "Drive query, e.g. name contains 'report'" },
      { key: 'file', label: 'File to upload', kind: 'text', default: '', hint: 'e.g. {{ $json.file.path }}; empty = upload Content as text' },
      { key: 'name', label: 'File name (upload)', kind: 'text', default: '' },
      { key: 'content', label: 'Content (upload)', kind: 'text', default: '' },
      { key: 'mimeType', label: 'Type (upload)', kind: 'text', default: 'text/plain' },
      { key: 'folderId', label: 'Folder ID (upload)', kind: 'text', default: '', hint: 'empty = My Drive' },
      { key: 'fileId', label: 'File ID (download)', kind: 'text', default: '' },
      { key: 'downloadAs', label: 'Download as', kind: 'select', default: 'text', options: ['text', 'file'] },
    ],
    run: (run) => perItem(run, (i) => drive(run, i)),
    resume: apiResume('Google Drive', driveItems),
  },
];
