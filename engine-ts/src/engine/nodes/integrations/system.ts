/**
 * Execute Command: runs a shell command in the phone's own shell, or in the
 * Ubuntu that FlowDroid installs inside itself (proot). The host carries it
 * out and returns its output.
 */

import { fail } from '../../../errors.ts';
import { formatNumber, getKey, isObj, toNum, toTemplateStr, type Obj } from '../../../value.ts';
import type { Item } from '../../context.ts';
import { itemsOf, paramText, paramValue, type NodeRun, type NodeSpec } from '../spec.ts';

function commandEffect(run: NodeRun): { effect: Obj } {
  const target = paramText(run, 'target', 0);
  if (target !== 'phone' && target !== 'ubuntu') fail('NodeError', `unknown target ${target}`);
  const commands = itemsOf(run).map((_, i): Obj => {
    const command = paramText(run, 'command', i);
    if (command === '') fail('NodeError', 'command is empty');
    const timeout = toNum(paramValue(run, 'timeout', i));
    return {
      target,
      command,
      workdir: paramText(run, 'workdir', i),
      timeoutMs: (timeout > 0 ? timeout : 60) * 1000,
    };
  });
  return { effect: { type: 'command', commands } };
}

function commandItems(run: NodeRun, result: Obj): Item[][] {
  const error = getKey(result, 'error');
  if (typeof error === 'string') fail('NodeError', error);
  const results = getKey(result, 'results');
  if (!Array.isArray(results) || results.length !== itemsOf(run).length) {
    fail('NodeError', `expected ${itemsOf(run).length} command results`);
  }
  const ignoreExit = getKey(run.params, 'ignoreExitCode') === true;
  return [
    results.map((r): Item => {
      const res = isObj(r) ? r : {};
      const failed = getKey(res, 'error');
      if (typeof failed === 'string') fail('NodeError', failed);
      const exitCode = toNum(getKey(res, 'exitCode'));
      const stdout = toTemplateStr(getKey(res, 'stdout'));
      const stderr = toTemplateStr(getKey(res, 'stderr'));
      if (exitCode !== 0 && !ignoreExit) {
        fail('NodeError', `command exited with code ${formatNumber(exitCode)}${stderr === '' ? '' : `: ${stderr.trim()}`}`);
      }
      return { exitCode, stdout, stderr };
    }),
  ];
}

export const systemNodes: NodeSpec[] = [
  {
    type: 'system.command',
    label: 'Execute Command',
    group: 'system',
    description: 'Runs a shell command on the phone or in FlowDroid’s built-in Ubuntu and outputs what it printed.',
    inputs: 1,
    outputs: ['main'],
    params: [
      { key: 'target', label: 'Run in', kind: 'select', default: 'phone', options: ['phone', 'ubuntu'] },
      { key: 'command', label: 'Command', kind: 'text', default: 'echo hello' },
      { key: 'workdir', label: 'Working directory', kind: 'text', default: '', hint: 'empty = home' },
      { key: 'timeout', label: 'Timeout (seconds)', kind: 'number', default: 60 },
      { key: 'ignoreExitCode', label: 'Continue on non-zero exit', kind: 'boolean', default: false },
    ],
    run: commandEffect,
    resume: commandItems,
  },
];
