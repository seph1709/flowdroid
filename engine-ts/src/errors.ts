/**
 * Every failure the core reports is an `Error` whose message starts with one of
 * these kinds, e.g. `InputError: workflow.nodes must be an array`. Hosts can
 * match on the prefix; the Rust port returns the same text as `Err(...)`.
 */
export type ErrorKind = 'InputError' | 'ExpressionError' | 'NodeError' | 'CronError';

export function fail(kind: ErrorKind, message: string): never {
  throw new Error(`${kind}: ${message}`);
}

export function messageOf(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
