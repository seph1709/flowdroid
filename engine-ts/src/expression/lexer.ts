import { fail } from '../errors.ts';

export type TokenKind = 'num' | 'str' | 'ident' | 'op' | 'end';

export interface Token {
  kind: TokenKind;
  /** Operator or identifier text, or the decoded string literal. */
  text: string;
  /** Numeric value of a `num` token. */
  value: number;
}

/** Longest operators first so `===` wins over `==` and `=`. */
const OPERATORS = [
  '===', '!==',
  '==', '!=', '<=', '>=', '&&', '||', '??',
  '<', '>', '+', '-', '*', '/', '%', '!', '?', ':', '.', ',', '(', ')', '[', ']',
];

const ESCAPES: Record<string, string> = { n: '\n', t: '\t', r: '\r', b: '\b', f: '\f', v: '\v', '0': '\0' };

const isDigit = (c: string): boolean => c >= '0' && c <= '9';
const isIdentStart = (c: string): boolean => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_' || c === '$';
const isIdentPart = (c: string): boolean => isIdentStart(c) || isDigit(c);
const isSpace = (c: string): boolean => c === ' ' || c === '\t' || c === '\n' || c === '\r';

export function tokenize(src: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src.charAt(i);
    if (isSpace(c)) {
      i++;
    } else if (isDigit(c)) {
      i = readNumber(src, i, tokens);
    } else if (c === '"' || c === "'") {
      i = readString(src, i, tokens);
    } else if (isIdentStart(c)) {
      let j = i + 1;
      while (j < src.length && isIdentPart(src.charAt(j))) j++;
      tokens.push({ kind: 'ident', text: src.slice(i, j), value: 0 });
      i = j;
    } else {
      const op = OPERATORS.find((o) => src.startsWith(o, i));
      if (op === undefined) fail('ExpressionError', 'unexpected character');
      tokens.push({ kind: 'op', text: op, value: 0 });
      i += op.length;
    }
  }
  tokens.push({ kind: 'end', text: '', value: 0 });
  return tokens;
}

function readNumber(src: string, start: number, tokens: Token[]): number {
  let j = start;
  while (j < src.length && isDigit(src.charAt(j))) j++;
  if (src.charAt(j) === '.' && isDigit(src.charAt(j + 1))) {
    j++;
    while (j < src.length && isDigit(src.charAt(j))) j++;
  }
  const text = src.slice(start, j);
  tokens.push({ kind: 'num', text, value: Number(text) });
  return j;
}

function readString(src: string, start: number, tokens: Token[]): number {
  const quote = src.charAt(start);
  let out = '';
  let j = start + 1;
  while (j < src.length && src.charAt(j) !== quote) {
    if (src.charAt(j) === '\\' && j + 1 < src.length) {
      const e = src.charAt(j + 1);
      out += ESCAPES[e] ?? e;
      j += 2;
    } else {
      out += src.charAt(j);
      j++;
    }
  }
  if (j >= src.length) fail('ExpressionError', 'unterminated string');
  tokens.push({ kind: 'str', text: out, value: 0 });
  return j + 1;
}
