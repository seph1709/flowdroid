/** Static checks the editor shows before a workflow runs. */

import { checkTemplates } from '../expression/template.ts';
import { isTrigger, specFor } from './nodes/registry.ts';
import { nodeById, type Workflow } from './workflow.ts';

export function validate(wf: Workflow): string[] {
  const issues: string[] = [];
  if (!wf.nodes.some((n) => isTrigger(n.type))) issues.push('workflow has no trigger node');
  const ids = new Set<string>();
  const names = new Set<string>();
  for (const node of wf.nodes) {
    if (ids.has(node.id)) issues.push(`duplicate node id ${node.id}`);
    if (names.has(node.name)) issues.push(`duplicate node name ${node.name}`);
    ids.add(node.id);
    names.add(node.name);
    if (specFor(node.type) === undefined) issues.push(`${node.name}: unknown node type ${node.type}`);
    checkTemplates(node.params, (message) => issues.push(`${node.name}: ${message}`));
  }
  wf.connections.forEach((c, i) => {
    if (nodeById(wf, c.from) === undefined) issues.push(`connection ${i}: unknown source node ${c.from}`);
    if (nodeById(wf, c.to) === undefined) issues.push(`connection ${i}: unknown target node ${c.to}`);
  });
  return issues;
}
