/**
 * Public API of the FlowDroid workflow core.
 *
 * Every function takes and returns strings and numbers only, with JSON
 * documents as text, so the same surface works across the Rust port, FFI and
 * Dart. Errors are thrown as `Error("<Kind>: message")`; see `errors.ts`.
 */

import { fail } from './errors.ts';
import { resume, start } from './engine/executor.ts';
import { catalog } from './engine/nodes/registry.ts';
import { parseState, serializeState } from './engine/state.ts';
import { validate } from './engine/validate.ts';
import { parseWorkflow } from './engine/workflow.ts';
import { renderTemplate } from './expression/template.ts';
import { nextRun } from './cron.ts';
import { parseJson } from './json.ts';
import { checkTime } from './time.ts';
import { isObj, stringify } from './value.ts';

/** Renders a `{{ }}` template against a JSON object of variables; returns the result as JSON. */
export function evaluateTemplate(template: string, contextJson: string): string {
  const ctx = parseJson(contextJson, 'context');
  if (!isObj(ctx)) fail('InputError', 'context must be an object');
  return stringify(renderTemplate(template, ctx));
}

/** Returns a JSON list of problems (empty when the workflow looks runnable). */
export function validateWorkflow(workflowJson: string): string {
  return stringify(validate(parseWorkflow(workflowJson)));
}

/** Returns the JSON catalog of node types the editor offers. */
export function nodeCatalog(): string {
  return stringify(catalog());
}

/**
 * Starts a run at `triggerNodeId` with the trigger's items (a JSON list of
 * objects; an empty list means one empty item). Returns the execution state.
 */
export function startExecution(workflowJson: string, triggerNodeId: string, itemsJson: string, nowMs: number): string {
  const wf = parseWorkflow(workflowJson);
  const items = parseJson(itemsJson, 'items');
  if (!Array.isArray(items) || !items.every(isObj)) fail('InputError', 'items must be a list of objects');
  const now = checkTime(nowMs, 'InputError', 'now');
  return serializeState(start(wf, triggerNodeId, items.length === 0 ? [{}] : items, now));
}

/** Continues a `waiting` execution with the host's result for `pending.effect`. */
export function resumeExecution(workflowJson: string, stateJson: string, resultJson: string, nowMs: number): string {
  const wf = parseWorkflow(workflowJson);
  const state = parseState(stateJson, wf);
  const result = parseJson(resultJson, 'effect result');
  if (!isObj(result)) fail('InputError', 'effect result must be an object');
  const now = checkTime(nowMs, 'InputError', 'now');
  return serializeState(resume(wf, state, result, now));
}

/** Next run of a cron expression after `afterMs` (UTC ms); -1 if it never fires. */
export function nextCronRun(expression: string, afterMs: number, utcOffsetMinutes: number): number {
  return nextRun(expression, afterMs, utcOffsetMinutes);
}
