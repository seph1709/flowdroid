import { clone, getKey, setKey, type Obj } from '../../value.ts';
import type { WorkflowNode } from '../workflow.ts';
import { androidNodes } from './android.ts';
import { phoneNodes } from './phone.ts';
import { dataNodes } from './data.ts';
import { flowNodes } from './flow.ts';
import { httpNodes } from './http.ts';
import { browserNodes } from './browser.ts';
import type { NodeSpec } from './spec.ts';
import { triggerNodes } from './triggers.ts';
import { aiNodes } from './integrations/ai.ts';
import { knowledgeNodes } from './integrations/knowledge.ts';
import { databaseNodes } from './integrations/databases.ts';
import { googleNodes } from './integrations/google.ts';
import { messagingNodes } from './integrations/messaging.ts';
import { systemNodes } from './integrations/system.ts';
import { agentNodes } from './integrations/agent.ts';
import { emailNodes } from './integrations/email.ts';
import { fileNodes } from './integrations/files.ts';
import { codeNodes } from './code.ts';
import { controlNodes } from './control.ts';
import { mcpNodes } from './integrations/mcp.ts';

export const NODE_SPECS: NodeSpec[] = [
  ...triggerNodes,
  ...flowNodes,
  ...controlNodes,
  ...dataNodes,
  ...codeNodes,
  ...httpNodes,
  ...browserNodes,
  ...androidNodes,
  ...phoneNodes,
  ...aiNodes,
  ...knowledgeNodes,
  ...agentNodes,
  ...mcpNodes,
  ...messagingNodes,
  ...emailNodes,
  ...databaseNodes,
  ...googleNodes,
  ...systemNodes,
  ...fileNodes,
];

export function specFor(type: string): NodeSpec | undefined {
  return NODE_SPECS.find((spec) => spec.type === type);
}

export function isTrigger(type: string): boolean {
  return specFor(type)?.group === 'trigger';
}

/** The node's parameters, with each missing one set to its spec default. */
export function paramsWithDefaults(spec: NodeSpec, node: WorkflowNode): Obj {
  const params: Obj = {};
  for (const param of spec.params) setKey(params, param.key, clone(param.default));
  for (const key of Object.keys(node.params)) setKey(params, key, getKey(node.params, key));
  return params;
}

/** The catalog the editor renders: every node type without its behavior. */
export function catalog(): Obj[] {
  return NODE_SPECS.map((spec) => ({
    type: spec.type,
    label: spec.label,
    group: spec.group,
    description: spec.description,
    inputs: spec.inputs,
    outputs: spec.outputs,
    params: spec.params.map((p) => ({
      key: p.key,
      label: p.label,
      kind: p.kind,
      default: p.default,
      options: p.options ?? null,
      hint: p.hint ?? null,
    })),
  }));
}
