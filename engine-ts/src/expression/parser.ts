/**
 * Recursive-descent parser for the expression language: a safe subset of
 * JavaScript expressions (no assignment, functions or object literals).
 *
 *   conditional := nullish ('?' conditional ':' conditional)?
 *   nullish     := or ('??' or)*
 *   or          := and ('||' and)*
 *   and         := equality ('&&' equality)*
 *   equality    := relational (('==' | '!=' | '===' | '!==') relational)*
 *   relational  := additive (('<' | '<=' | '>' | '>=') additive)*
 *   additive    := multiplicative (('+' | '-') multiplicative)*
 *   multiplicative := unary (('*' | '/' | '%') unary)*
 *   unary       := ('!' | '-') unary | postfix
 *   postfix     := primary ('.' ident | '[' conditional ']' | '(' args ')')*
 *   primary     := number | string | true | false | null | undefined
 *                | ident | '(' conditional ')' | '[' args ']'
 */

import { fail } from '../errors.ts';
import type { Expr } from './ast.ts';
import { tokenize, type Token } from './lexer.ts';

/** Nesting limit, so recursion stays bounded in every port. */
export const MAX_NESTING = 64;

const BINARY_LEVELS: string[][] = [
  ['??'],
  ['||'],
  ['&&'],
  ['==', '!=', '===', '!=='],
  ['<', '<=', '>', '>='],
  ['+', '-'],
  ['*', '/', '%'],
];

const KEYWORDS: Record<string, Expr> = {
  true: { kind: 'literal', value: true },
  false: { kind: 'literal', value: false },
  null: { kind: 'literal', value: null },
  undefined: { kind: 'literal', value: null },
};

export function parseExpression(src: string): Expr {
  const parser = new Parser(tokenize(src));
  if (parser.peek().kind === 'end') fail('ExpressionError', 'empty expression');
  const expr = parser.conditional();
  if (parser.peek().kind !== 'end') parser.unexpected();
  return expr;
}

class Parser {
  private readonly tokens: Token[];
  private pos = 0;
  private depth = 0;

  constructor(tokens: Token[]) {
    this.tokens = tokens;
  }

  peek(): Token {
    return this.tokens[this.pos] ?? this.tokens[this.tokens.length - 1]!;
  }

  unexpected(): never {
    const t = this.peek();
    if (t.kind === 'end') fail('ExpressionError', 'unexpected end of expression');
    if (t.kind === 'str') fail('ExpressionError', 'unexpected string');
    if (t.kind === 'num') fail('ExpressionError', 'unexpected number');
    fail('ExpressionError', `unexpected '${t.text}'`);
  }

  conditional(): Expr {
    this.enter();
    const test = this.binary(0);
    let result = test;
    if (this.acceptOp('?')) {
      const then = this.conditional();
      this.expectOp(':');
      result = { kind: 'conditional', test, then, otherwise: this.conditional() };
    }
    this.depth--;
    return result;
  }

  private binary(level: number): Expr {
    const ops = BINARY_LEVELS[level];
    if (ops === undefined) return this.unary();
    let left = this.binary(level + 1);
    for (;;) {
      const t = this.peek();
      if (t.kind !== 'op' || !ops.includes(t.text)) return left;
      this.pos++;
      left = { kind: 'binary', op: t.text, left, right: this.binary(level + 1) };
    }
  }

  private unary(): Expr {
    const t = this.peek();
    if (t.kind === 'op' && (t.text === '!' || t.text === '-')) {
      this.pos++;
      this.enter();
      const operand = this.unary();
      this.depth--;
      return { kind: 'unary', op: t.text, operand };
    }
    return this.postfix();
  }

  private postfix(): Expr {
    let expr = this.primary();
    for (;;) {
      if (this.acceptOp('.')) {
        const name = this.peek();
        if (name.kind !== 'ident') this.unexpected();
        this.pos++;
        expr = { kind: 'member', object: expr, property: { kind: 'literal', value: name.text } };
      } else if (this.acceptOp('[')) {
        const property = this.conditional();
        this.expectOp(']');
        expr = { kind: 'member', object: expr, property };
      } else if (this.acceptOp('(')) {
        expr = { kind: 'call', callee: expr, args: this.list(')') };
      } else {
        return expr;
      }
    }
  }

  private primary(): Expr {
    const t = this.peek();
    this.pos++;
    switch (t.kind) {
      case 'num':
        return { kind: 'literal', value: t.value };
      case 'str':
        return { kind: 'literal', value: t.text };
      case 'ident':
        return Object.hasOwn(KEYWORDS, t.text) ? KEYWORDS[t.text]! : { kind: 'ident', name: t.text };
      case 'op':
        if (t.text === '(') {
          const inner = this.conditional();
          this.expectOp(')');
          return inner;
        }
        if (t.text === '[') return { kind: 'array', items: this.list(']') };
        break;
      case 'end':
        break;
    }
    this.pos--;
    return this.unexpected();
  }

  /** Comma-separated expressions up to `close`; the opener is already consumed. */
  private list(close: string): Expr[] {
    const items: Expr[] = [];
    if (this.acceptOp(close)) return items;
    do items.push(this.conditional());
    while (this.acceptOp(','));
    this.expectOp(close);
    return items;
  }

  private enter(): void {
    this.depth++;
    if (this.depth > MAX_NESTING) fail('ExpressionError', 'expression is nested too deeply');
  }

  private acceptOp(text: string): boolean {
    const t = this.peek();
    if (t.kind === 'op' && t.text === text) {
      this.pos++;
      return true;
    }
    return false;
  }

  private expectOp(text: string): void {
    if (!this.acceptOp(text)) this.unexpected();
  }
}
