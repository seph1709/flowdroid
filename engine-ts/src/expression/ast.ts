import type { Val } from '../value.ts';

export type Expr =
  | { kind: 'literal'; value: Val }
  | { kind: 'ident'; name: string }
  | { kind: 'array'; items: Expr[] }
  | { kind: 'member'; object: Expr; property: Expr }
  | { kind: 'call'; callee: Expr; args: Expr[] }
  | { kind: 'unary'; op: '!' | '-'; operand: Expr }
  | { kind: 'binary'; op: string; left: Expr; right: Expr }
  | { kind: 'conditional'; test: Expr; then: Expr; otherwise: Expr };
