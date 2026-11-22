/**
 * Files between steps travel as references, never as bytes:
 *   { path, name, mimeType, size }   (path is inside FlowDroid's folder)
 * Steps name files by path; the host reads, sends and saves the bytes.
 */

import { getKey, isObj, type Val } from '../../value.ts';
import { paramValue, type NodeRun } from './spec.ts';

const TYPES: Record<string, string> = {
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', heic: 'image/heic',
  pdf: 'application/pdf', txt: 'text/plain', md: 'text/markdown', csv: 'text/csv', json: 'application/json',
  html: 'text/html', htm: 'text/html', xml: 'application/xml', mp3: 'audio/mpeg', m4a: 'audio/mp4', wav: 'audio/wav',
  ogg: 'audio/ogg', mp4: 'video/mp4', zip: 'application/zip',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};

/** The media type for a file name, from its extension. */
export function mimeFromPath(path: string): string {
  const dot = path.lastIndexOf('.');
  const ext = dot < 0 ? '' : path.slice(dot + 1).toLowerCase();
  return TYPES[ext] ?? 'application/octet-stream';
}

export function isImagePath(path: string): boolean {
  return mimeFromPath(path).startsWith('image/');
}

function pathOf(v: Val): string {
  if (typeof v === 'string') return v.trim();
  if (isObj(v)) {
    const p = getKey(v, 'path');
    return typeof p === 'string' ? p.trim() : '';
  }
  return '';
}

/**
 * File paths from a parameter: a path, several separated by commas or new
 * lines, a file reference ({{ $json.file }}), or a list of either.
 */
export function filePaths(run: NodeRun, key: string, index: number): string[] {
  const v = paramValue(run, key, index);
  const parts = Array.isArray(v)
    ? v.map(pathOf)
    : typeof v === 'string'
      ? v.split(/[,\n]/).map((s) => s.trim())
      : [pathOf(v)];
  return parts.filter((p) => p !== '');
}

/** The first file path of a parameter, or ''. */
export function filePath(run: NodeRun, key: string, index: number): string {
  return filePaths(run, key, index)[0] ?? '';
}

/** Where the host puts a file's bytes, base64-encoded, before sending a request. */
export function fileMarker(path: string): string {
  return `@@flowdroid-file-base64:${path}@@`;
}
