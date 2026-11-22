/** Sample workflows shared by the engine tests and the recorded Rust-port cases. */

type Node = {
  id: string;
  name?: string;
  type: string;
  params?: object;
  disabled?: boolean;
  continueOnFail?: boolean;
  pinned?: object[];
  retryOnFail?: boolean;
  maxTries?: number;
  waitBetweenTries?: number;
};
type Conn = { from: string; to: string; output?: number; input?: number };

export const workflow = (nodes: Node[], connections: Conn[], variables: object = {}, extra: object = {}): string =>
  JSON.stringify({ id: 'wf', name: 'Test', variables, nodes, connections, ...extra });

const manual: Node = { id: 'start', name: 'Start', type: 'trigger.manual' };

export const fixtures = {
  setAndIf: workflow(
    [
      manual,
      {
        id: 'set', name: 'Set', type: 'core.set',
        params: { fields: [
          { name: 'greeting', value: '{{ $vars.hello + ", " + $json.name }}' },
          { name: 'meta.index', value: '{{ $index }}' },
          { name: 'meta.at', value: '{{ $now }}' },
        ] },
      },
      { id: 'if', name: 'Adult?', type: 'core.if', params: { conditions: [{ left: '{{ $json.age }}', op: 'gte', right: '18' }] } },
      { id: 'yes', name: 'Yes', type: 'core.noop' },
      { id: 'no', name: 'No', type: 'core.set', params: { keepOnlySet: true, fields: [{ name: 'minor', value: '{{ $json.name }}' }] } },
    ],
    [
      { from: 'start', to: 'set' },
      { from: 'set', to: 'if' },
      { from: 'if', output: 0, to: 'yes' },
      { from: 'if', output: 1, to: 'no' },
    ],
    { hello: 'Hi' },
  ),

  dataPipeline: workflow(
    [
      manual,
      { id: 'split', name: 'Split', type: 'core.splitOut', params: { field: 'orders' } },
      { id: 'dedupe', name: 'Dedupe', type: 'core.removeDuplicates', params: { field: 'id' } },
      { id: 'filter', name: 'Big', type: 'core.filter', params: { combine: 'or', conditions: [
        { left: '{{ $json.total }}', op: 'gt', right: 50 },
        { left: '{{ $json.tags }}', op: 'contains', right: 'vip' },
      ] } },
      { id: 'sort', name: 'Sort', type: 'core.sort', params: { field: 'total', order: 'desc' } },
      { id: 'limit', name: 'Top', type: 'core.limit', params: { max: 2 } },
      { id: 'agg', name: 'Collect', type: 'core.aggregate', params: { field: 'id' } },
    ],
    [
      { from: 'start', to: 'split' }, { from: 'split', to: 'dedupe' }, { from: 'dedupe', to: 'filter' },
      { from: 'filter', to: 'sort' }, { from: 'sort', to: 'limit' }, { from: 'limit', to: 'agg' },
    ],
  ),

  switchMerge: workflow(
    [
      manual,
      { id: 'sw', name: 'Route', type: 'core.switch', params: { fallback: true, rules: [
        { left: '{{ $json.kind }}', op: 'equals', right: 'a' },
        { left: '{{ $json.kind }}', op: 'startsWith', right: 'b' },
      ] } },
      { id: 'ta', name: 'Tag A', type: 'core.set', params: { fields: [{ name: 'route', value: 'A' }] } },
      { id: 'tb', name: 'Tag B', type: 'core.set', params: { fields: [{ name: 'route', value: 'B' }] } },
      { id: 'merge', name: 'Merge', type: 'core.merge', params: { mode: 'append' } },
      { id: 'pair', name: 'Pair', type: 'core.merge', params: { mode: 'combineByIndex' } },
    ],
    [
      { from: 'start', to: 'sw' },
      { from: 'sw', output: 0, to: 'ta' },
      { from: 'sw', output: 1, to: 'tb' },
      { from: 'ta', to: 'merge', input: 0 },
      { from: 'tb', to: 'merge', input: 1 },
      { from: 'merge', to: 'pair', input: 0 },
      { from: 'sw', output: 2, to: 'pair', input: 1 },
    ],
  ),

  httpThenNotify: workflow(
    [
      { id: 'hook', name: 'Webhook', type: 'trigger.webhook', params: { path: 'orders' } },
      { id: 'http', name: 'Fetch', type: 'http.request', params: {
        method: 'post', url: 'https://api.example.com/users/{{ $json.body.id }}',
        headers: [{ name: 'Authorization', value: 'Bearer {{ $vars.token }}' }, { name: '', value: 'skipped' }],
        body: '{{ $json.body }}',
      } },
      { id: 'note', name: 'Notify', type: 'android.notify', params: { title: 'User {{ $json.name }}', body: '{{ $node["Webhook"].json.body.id }}' } },
      { id: 'resp', name: 'Respond', type: 'core.respond', params: { status: 201 } },
    ],
    [{ from: 'hook', to: 'http' }, { from: 'http', to: 'note' }, { from: 'note', to: 'resp' }],
    { token: 'secret' },
  ),

  deviceNodes: workflow(
    [
      manual,
      { id: 'bat', name: 'Battery', type: 'android.battery' },
      { id: 'loc', name: 'Where', type: 'android.location', params: { field: 'pos' } },
      { id: 'clip', name: 'Clip', type: 'android.clipboardRead' },
      { id: 'say', name: 'Say', type: 'android.speak', params: { text: 'Battery at {{ $json.battery.level }} percent' } },
      { id: 'vib', name: 'Buzz', type: 'android.vibrate', params: { ms: '{{ $json.battery.level * 10 }}' } },
      { id: 'wait', name: 'Wait', type: 'core.wait', params: { seconds: 1.5 } },
      { id: 'copy', name: 'Copy', type: 'android.clipboardWrite', params: { text: '{{ $json.pos.latitude }},{{ $json.pos.longitude }}' } },
      { id: 'open', name: 'Map', type: 'android.openUrl', params: { url: 'geo:{{ $json.pos.latitude }},{{ $json.pos.longitude }}' } },
    ],
    [
      { from: 'start', to: 'bat' }, { from: 'bat', to: 'loc' }, { from: 'loc', to: 'clip' }, { from: 'clip', to: 'say' },
      { from: 'say', to: 'vib' }, { from: 'vib', to: 'wait' }, { from: 'wait', to: 'copy' }, { from: 'copy', to: 'open' },
    ],
  ),

  failures: workflow(
    [
      manual,
      { id: 'bad', name: 'Bad Expr', type: 'core.set', continueOnFail: true, params: { fields: [{ name: 'x', value: '{{ $json.a.reverse() }}' }] } },
      { id: 'off', name: 'Disabled', type: 'core.limit', disabled: true, params: { max: 0 } },
      { id: 'boom', name: 'Boom', type: 'core.splitOut', params: { field: 'missing' } },
    ],
    [{ from: 'start', to: 'bad' }, { from: 'bad', to: 'off' }, { from: 'off', to: 'boom' }],
  ),

  loop: workflow(
    [manual, { id: 'a', name: 'A', type: 'core.noop' }, { id: 'b', name: 'B', type: 'core.noop' }],
    [{ from: 'start', to: 'a' }, { from: 'a', to: 'b' }, { from: 'b', to: 'a' }],
  ),

  invalid: workflow(
    [
      { id: 'x', type: 'core.noop' },
      { id: 'x', name: 'x', type: 'core.mystery', params: { v: '{{ 1 + }}' } },
    ],
    [{ from: 'x', to: 'ghost' }],
  ),
};
