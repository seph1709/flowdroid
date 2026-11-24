import 'dart:convert';

import 'dart:async';

import '../core/execution_state.dart';
import '../core/json.dart';
import '../core/layout.dart';
import '../core/node_catalog.dart';
import '../core/workflow.dart';
import '../data/execution_record.dart';
import '../runtime/browser/browser_driver.dart';
import '../ui/editor/editor_controller.dart';

/// A tool the assistant can call: what it does and the JSON Schema of its input.
class ToolSpec {
  const ToolSpec(this.name, this.description, this.schema);

  final String name;
  final String description;
  final JsonMap schema;
}

/// What a tool call returned: text for the model, and a short line for the chat.
class ToolOutcome {
  const ToolOutcome(this.text, {this.summary, this.isError = false, this.changed = false});

  final String text;
  final String? summary;
  final bool isError;

  /// The workflow was edited.
  final bool changed;
}

class ToolInputError implements Exception {
  const ToolInputError(this.message);

  final String message;
}

/// Asks the person before the assistant really runs steps (they may send
/// messages, call APIs or change things). True means go ahead.
typedef RunApproval = Future<bool> Function(String what);

JsonMap _object(Map<String, Object> properties, [List<String> required = const []]) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
  'additionalProperties': false,
};

const _nodeRef = {'type': 'string', 'description': 'The step’s name (or id).'};

/// The tools that let an assistant read, build, edit, run and debug the
/// workflow open in [controller]. Every edit goes through the controller, so
/// the canvas updates live and one reply undoes as one step.
class WorkflowTools {
  WorkflowTools({
    required this.controller,
    required this.approveRun,
    this.credentialNames,
    this.workflowList,
    this.onChanged,
  });

  /// Called after each edit, e.g. to bring the steps into view.
  final void Function()? onChanged;

  final EditorController controller;
  final RunApproval approveRun;

  /// Saved credentials as `{name, type}` (never their secrets).
  final Future<List<JsonMap>> Function()? credentialNames;

  /// Other workflows as `{id, name}`, for Execute Workflow and error workflows.
  final Future<List<JsonMap>> Function()? workflowList;

  /// The undo group for the current reply.
  String group = 'assistant';

  /// The editor was closed; tools do nothing.
  bool closed = false;

  Workflow get _wf => controller.workflow;
  List<NodeType> get _catalog => controller.services.catalog;

  static final specs = <ToolSpec>[
    ToolSpec(
      'list_node_types',
      'Every kind of step FlowDroid has, grouped (trigger, flow, data, network, android, ai, …): '
          'type id, label and what it does. Call describe_node_types before using one.',
      _object({}),
    ),
    ToolSpec(
      'describe_node_types',
      'Full details of some step types: inputs, outputs, and every parameter with its kind, default, options and '
          'the exact shape structured parameters take.',
      _object(
        {
          'types': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Type ids such as "http.request" or "android.notify".',
          },
        },
        ['types'],
      ),
    ),
    ToolSpec(
      'get_workflow',
      'The open workflow: its steps with parameters, the connections between them, its variables, and problems the '
          'checker found. Read it before editing.',
      _object({}),
    ),
    ToolSpec(
      'add_node',
      'Adds a step. Parameters you leave out keep their defaults. Give "after" to connect it after an existing step.',
      _object(
        {
          'type': {'type': 'string', 'description': 'Step type id from list_node_types.'},
          'name': {'type': 'string', 'description': 'A short name that says what this step does (unique).'},
          'params': {'type': 'object', 'description': 'Parameter values by key.'},
          'after': {'type': 'string', 'description': 'Name of the step whose output feeds this one.'},
          'output': {'type': 'integer', 'description': 'Which output of "after" (0 = first; If: 0 true, 1 false).'},
        },
        ['type', 'name'],
      ),
    ),
    ToolSpec(
      'update_node',
      'Changes a step: parameters (merged into the current ones; null removes one), name, or its switches.',
      _object(
        {
          'node': _nodeRef,
          'params': {'type': 'object', 'description': 'Parameters to set, by key.'},
          'name': {'type': 'string', 'description': 'New name.'},
          'disabled': {'type': 'boolean'},
          'continueOnFail': {'type': 'boolean', 'description': 'Keep going with the error as output when it fails.'},
          'retryOnFail': {'type': 'boolean'},
        },
        ['node'],
      ),
    ),
    ToolSpec('remove_node', 'Deletes a step and its connections.', _object({'node': _nodeRef}, ['node'])),
    ToolSpec(
      'connect',
      'Connects an output of one step to an input of another.',
      _object(
        {
          'from': _nodeRef,
          'to': _nodeRef,
          'output': {'type': 'integer', 'description': 'Output index of "from" (default 0).'},
          'input': {'type': 'integer', 'description': 'Input index of "to" (default 0; Merge has 2).'},
        },
        ['from', 'to'],
      ),
    ),
    ToolSpec(
      'disconnect',
      'Removes connections from one step to another (all of them, or only the given output).',
      _object(
        {
          'from': _nodeRef,
          'to': _nodeRef,
          'output': {'type': 'integer'},
        },
        ['from', 'to'],
      ),
    ),
    ToolSpec(
      'set_workflow',
      'Renames the workflow or replaces its variables (read in expressions as \$vars.name).',
      _object({
        'name': {'type': 'string'},
        'variables': {'type': 'object'},
      }),
    ),
    ToolSpec(
      'list_credentials',
      'Saved credentials (name and type only). A credential parameter takes the credential’s name.',
      _object({}),
    ),
    ToolSpec('list_workflows', 'The other workflows on this phone: id and name.', _object({})),
    ToolSpec(
      'run_workflow',
      'Really runs the workflow from a trigger (asks the person first) and returns each step’s status, error and '
          'output sample. Use it to test and debug.',
      _object({
        'trigger': {'type': 'string', 'description': 'Trigger step to start from; the first one if left out.'},
      }),
    ),
    ToolSpec(
      'run_step',
      'Really runs one step on the input its earlier steps produced in the last run (asks first), and returns its '
          'output or error. Quick to test a fix.',
      _object({'node': _nodeRef}, ['node']),
    ),
    ToolSpec(
      'browse',
      'Looks at a website in FlowDroid’s browser, with the person’s saved logins, to learn how to automate it. '
          'Actions: open (url), read, click (target), type (target, text), press (text: key), scroll, back. Returns '
          'the page: title, address, numbered elements each with a stable "target" to use in Browser step scripts, '
          'and the page text. Use it instead of asking the person for selectors. Look and navigate; do not submit, '
          'buy, send or delete anything unless the person asked for exactly that.',
      _object(
        {
          'action': {
            'type': 'string',
            'enum': ['open', 'read', 'click', 'type', 'press', 'scroll', 'back'],
          },
          'url': {'type': 'string', 'description': 'For open: the full address.'},
          'target': {'type': 'string', 'description': 'An element number from the last view, or a target it gave.'},
          'text': {'type': 'string', 'description': 'For type: the text. For press: a key such as Enter.'},
        },
        ['action'],
      ),
    ),
    ToolSpec(
      'log_in_to_site',
      'Opens a site on screen so the person logs in themselves (you never see or type their password), then '
          'keeps that login for every automation until the site ends it. Use it when browse lands on a login page.',
      _object(
        {
          'url': {'type': 'string', 'description': 'The site’s login page or home page.'},
        },
        ['url'],
      ),
    ),
    ToolSpec(
      'get_last_run',
      'The last run of this workflow: status, error, and every step’s result with a sample of its output.',
      _object({}),
    ),
    ToolSpec(
      'get_step_output',
      'All items a step output in the last run (cut when long).',
      _object(
        {
          'node': _nodeRef,
          'limit': {'type': 'integer', 'description': 'Most items to return (default 10).'},
        },
        ['node'],
      ),
    ),
  ];

  Future<ToolOutcome> call(String name, JsonMap input) async {
    if (closed) return const ToolOutcome('the workflow editor was closed', isError: true);
    try {
      final outcome = await _dispatch(name, input);
      if (outcome.changed) onChanged?.call();
      return outcome;
    } on ToolInputError catch (e) {
      return ToolOutcome(e.message, isError: true, summary: e.message);
    }
  }

  Future<ToolOutcome> _dispatch(String name, JsonMap input) async {
    {
      return switch (name) {
        'list_node_types' => ToolOutcome(_listTypes(), summary: 'Looked at the step types'),
        'describe_node_types' => _describe(input),
        'get_workflow' => ToolOutcome(_encode(_workflowJson()), summary: 'Read the workflow'),
        'add_node' => _add(input),
        'update_node' => _update(input),
        'remove_node' => _remove(input),
        'connect' => _connect(input),
        'disconnect' => _disconnect(input),
        'set_workflow' => _setWorkflow(input),
        'list_credentials' => ToolOutcome(
          _encode(await credentialNames?.call() ?? const []),
          summary: 'Checked credentials',
        ),
        'list_workflows' => ToolOutcome(
          _encode((await workflowList?.call() ?? const []).where((w) => w['id'] != _wf.id).toList()),
          summary: 'Listed workflows',
        ),
        'run_workflow' => await _run(input),
        'run_step' => await _runStep(input),
        'browse' => await _browse(input),
        'log_in_to_site' => await _logIn(input),
        'get_last_run' => ToolOutcome(_encode(_runJson(controller.lastExecution)), summary: 'Read the last run'),
        'get_step_output' => _stepOutput(input),
        _ => ToolOutcome('unknown tool $name', isError: true),
      };
    }
  }

  // ---- reading ----

  String _listTypes() {
    final by = <NodeGroup, List<NodeType>>{};
    for (final t in _catalog) {
      by.putIfAbsent(t.group, () => []).add(t);
    }
    final b = StringBuffer();
    for (final MapEntry(key: group, value: types) in by.entries) {
      b.writeln('## ${group.name}');
      for (final t in types) {
        b.writeln('${t.type} — ${t.label}: ${t.description}');
      }
    }
    return '$b';
  }

  ToolOutcome _describe(JsonMap input) {
    final ids = asList(input['types']).whereType<String>().toList();
    final out = <Object?>[];
    for (final id in ids) {
      final t = controller.services.nodeType(id);
      if (t == null) {
        out.add({'type': id, 'error': 'no such step type; see list_node_types'});
        continue;
      }
      out.add({
        'type': t.type,
        'label': t.label,
        'description': t.description,
        'trigger': t.isTrigger,
        'inputs': t.inputs,
        'outputs': t.outputs ?? 'one per rule, plus fallback when on',
        'params': [
          for (final p in t.params)
            {
              'key': p.key,
              'label': p.label,
              'kind': p.kind.name,
              'default': p.defaultValue,
              if (p.options.isNotEmpty) 'options': p.options,
              if (p.hint != null) 'hint': p.hint,
              'shape': ?_shapes[p.kind],
            },
        ],
      });
    }
    return ToolOutcome(_encode(out), summary: 'Read about ${ids.join(', ')}');
  }

  static const _shapes = {
    ParamKind.conditions:
        'list of {"left": "{{ \$json.x }}", "op": "equals|notEquals|contains|notContains|startsWith|endsWith|gt|gte|lt|'
        'lte|isEmpty|isNotEmpty|isTrue|isFalse", "right": "value"}',
    ParamKind.rules: 'list of conditions ({left, op, right}); rule N sends matching items to output N',
    ParamKind.fields: 'list of {"name": "path.to.field", "value": "text or {{ expression }}"}',
    ParamKind.keyValues: 'list of {"name": "...", "value": "..."}',
    ParamKind.tools:
        'list of {"kind": "http|command|workflow|table|mcp|browser", "name": "tool_name", "description": "...", '
        '"config": "http: allowed URL prefix; workflow: workflow id; table: table name; '
        'browser: allowed sites, comma separated (empty = any)"}',
    ParamKind.credential: 'the name of a saved credential of one of the listed types (see list_credentials)',
    ParamKind.workflow: 'a workflow id (see list_workflows)',
    ParamKind.json: 'JSON text; may contain {{ expressions }}',
    ParamKind.code: 'source code text',
  };

  JsonMap _workflowJson() => {
    'name': _wf.name,
    'variables': _wf.variables,
    'steps': [
      for (final n in _wf.nodes)
        {
          'id': n.id,
          'name': n.name,
          'type': n.type,
          'params': n.params,
          if (n.disabled) 'disabled': true,
          if (n.continueOnFail) 'continueOnFail': true,
          if (n.pinned != null) 'pinnedItems': n.pinned!.length,
          if (controller.typeOf(n) case final t?) 'outputs': t.outputLabels(n.params),
        },
    ],
    'connections': [
      for (final c in _wf.connections)
        {'from': _nameOf(c.from), 'output': c.output, 'to': _nameOf(c.to), 'input': c.input},
    ],
    'problems': controller.issues,
  };

  String _nameOf(String id) => _wf.node(id)?.name ?? id;

  WorkflowNode _node(Object? ref) {
    final r = asString(ref).trim();
    for (final n in _wf.nodes) {
      if (n.name == r || n.id == r) return n;
    }
    for (final n in _wf.nodes) {
      if (n.name.toLowerCase() == r.toLowerCase()) return n;
    }
    throw ToolInputError('no step named "$r"; steps: ${_wf.nodes.map((n) => n.name).join(', ')}');
  }

  // ---- editing ----

  ToolOutcome _add(JsonMap input) {
    final typeId = asString(input['type']);
    final type = controller.services.nodeType(typeId);
    if (type == null) throw ToolInputError('no step type "$typeId"; see list_node_types');
    final params = asMap(input['params']);
    _checkKeys(type, params);
    final after = input['after'] == null ? null : _node(input['after']);
    final output = asInt(input['output']);
    if (after != null) _checkOutput(after, output);
    final node = controller.batch((wf) {
      final n = WorkflowNode(
        id: newId('n_'),
        name: wf.uniqueName(
          asString(input['name'], type.label).trim().isEmpty ? type.label : asString(input['name']).trim(),
        ),
        type: type.type,
        params: {...type.defaultParams(), ...params},
      );
      wf.nodes.add(n);
      if (after != null && type.inputs > 0) wf.connections.add(Connection(from: after.id, output: output, to: n.id));
      _layout(wf);
      return n;
    }, group: group);
    return ToolOutcome(
      _encode({'added': node.name, 'id': node.id, 'problems': controller.issues}),
      summary: 'Added “${node.name}”',
      changed: true,
    );
  }

  ToolOutcome _update(JsonMap input) {
    final node = _node(input['node']);
    final type = controller.typeOf(node);
    final params = asMap(input['params']);
    if (type != null) _checkKeys(type, params);
    controller.batch((wf) {
      for (final MapEntry(:key, :value) in params.entries) {
        if (value == null) {
          node.params.remove(key);
        } else {
          node.params[key] = value;
        }
      }
      final name = asString(input['name']).trim();
      if (name.isNotEmpty && name != node.name) node.name = wf.uniqueName(name);
      if (input['disabled'] is bool) node.disabled = input['disabled'] as bool;
      if (input['continueOnFail'] is bool) node.continueOnFail = input['continueOnFail'] as bool;
      if (input['retryOnFail'] is bool) node.retryOnFail = input['retryOnFail'] as bool;
    }, group: group);
    return ToolOutcome(
      _encode({'updated': node.name, 'params': node.params, 'problems': controller.issues}),
      summary: 'Changed “${node.name}”',
      changed: true,
    );
  }

  ToolOutcome _remove(JsonMap input) {
    final node = _node(input['node']);
    controller.batch((wf) => wf.removeNode(node.id), group: group);
    return ToolOutcome(_encode({'removed': node.name}), summary: 'Removed “${node.name}”', changed: true);
  }

  ToolOutcome _connect(JsonMap input) {
    final from = _node(input['from']);
    final to = _node(input['to']);
    final output = asInt(input['output']);
    final inputIndex = asInt(input['input']);
    if (from.id == to.id) throw const ToolInputError('a step can’t feed itself');
    _checkOutput(from, output);
    final inputs = controller.inputCount(to);
    if (inputIndex >= inputs) {
      throw ToolInputError(
        inputs == 0 ? '“${to.name}” is a trigger: it has no input' : '“${to.name}” has $inputs input(s)',
      );
    }
    controller.batch((wf) {
      final c = Connection(from: from.id, output: output, to: to.id, input: inputIndex);
      if (!wf.connections.contains(c)) wf.connections.add(c);
      _layout(wf);
    }, group: group);
    return ToolOutcome(
      _encode({'connected': '${from.name}[$output] → ${to.name}[$inputIndex]', 'problems': controller.issues}),
      summary: 'Connected “${from.name}” → “${to.name}”',
      changed: true,
    );
  }

  ToolOutcome _disconnect(JsonMap input) {
    final from = _node(input['from']);
    final to = _node(input['to']);
    final output = input['output'] == null ? null : asInt(input['output']);
    bool hit(Connection c) => c.from == from.id && c.to == to.id && (output == null || c.output == output);
    final count = _wf.connections.where(hit).length;
    if (count == 0) throw ToolInputError('“${from.name}” is not connected to “${to.name}”');
    controller.batch((wf) => wf.connections.removeWhere(hit), group: group);
    return ToolOutcome(
      _encode({'removedConnections': count}),
      summary: 'Disconnected “${from.name}” → “${to.name}”',
      changed: true,
    );
  }

  ToolOutcome _setWorkflow(JsonMap input) {
    controller.batch((wf) {
      final name = asString(input['name']).trim();
      if (name.isNotEmpty) wf.name = name;
      if (input['variables'] is Map) wf.variables = asMap(input['variables']);
    }, group: group);
    return ToolOutcome(
      _encode({'name': _wf.name, 'variables': _wf.variables}),
      summary: 'Updated the workflow',
      changed: true,
    );
  }

  void _checkKeys(NodeType type, JsonMap params) {
    final known = type.params.map((p) => p.key).toSet();
    final unknown = params.keys.where((k) => !known.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw ToolInputError('${type.type} has no parameter ${unknown.join(', ')}; it has ${known.join(', ')}');
    }
  }

  void _checkOutput(WorkflowNode node, int output) {
    final labels = controller.outputLabels(node);
    if (output < 0 || output >= labels.length) {
      throw ToolInputError('“${node.name}” has outputs ${[for (final (i, l) in labels.indexed) '$i=$l'].join(', ')}');
    }
  }

  void _layout(Workflow wf) => layoutVertically(wf, (n) => controller.typeOf(n)?.isTrigger ?? false);

  // ---- the browser ----

  Future<ToolOutcome> _browse(JsonMap input) async {
    final browser = controller.services.browser;
    if (browser == null) throw const ToolInputError('the browser is not available here');
    final action = asString(input['action']);
    try {
      final view = await browser.agent(input, '', session: 'assistant-${_wf.id}').timeout(const Duration(seconds: 60));
      final url = RegExp(r'^URL: (.*)$', multiLine: true).firstMatch(view)?.group(1) ?? '';
      final host = Uri.tryParse(url)?.host ?? '';
      return ToolOutcome(
        _cut(view),
        summary: switch (action) {
          'open' => 'Opened $host',
          'read' => 'Looked at $host',
          'click' => 'Clicked on $host',
          'type' => 'Typed on $host',
          _ => 'Browsed $host',
        },
      );
    } on BrowserException catch (e) {
      throw ToolInputError('browser: ${e.message}');
    } on TimeoutException {
      throw const ToolInputError('browser: the page took too long');
    }
  }

  Future<ToolOutcome> _logIn(JsonMap input) async {
    final url = asString(input['url']).trim();
    if (url.isEmpty) throw const ToolInputError('give the site to log in to');
    final r = await controller.services.browserLogins.logIn(url);
    if (r['error'] case final String error) {
      return ToolOutcome('could not show the login page: $error', summary: 'Login not shown', isError: true);
    }
    return ToolOutcome(
      _encode({'loggedIn': true, 'endedAt': r['url'], 'note': 'the person tapped Done; browse again to check'}),
      summary: 'You logged in to ${Uri.tryParse(url.startsWith('http') ? url : 'https://$url')?.host ?? url}',
    );
  }

  static String _cut(String s) => s.length > _maxText ? '${s.substring(0, _maxText)}… (cut)' : s;

  // ---- running ----

  Future<ToolOutcome> _run(JsonMap input) async {
    final trigger = input['trigger'] == null ? controller.triggers.firstOrNull : _node(input['trigger']);
    if (trigger == null) throw const ToolInputError('the workflow has no trigger to start from');
    if (controller.running) throw const ToolInputError('a run is already in progress');
    if (!await approveRun('run “${_wf.name}” from “${trigger.name}”')) {
      return const ToolOutcome('the person declined the run', summary: 'Run declined', isError: true);
    }
    final record = await controller.run(trigger);
    if (record == null) throw const ToolInputError('the run could not start');
    final failed = record.status != ExecutionStatus.success;
    return ToolOutcome(_encode(_runJson(record)), summary: failed ? 'Ran it: it failed' : 'Ran it: it worked');
  }

  Future<ToolOutcome> _runStep(JsonMap input) async {
    final node = _node(input['node']);
    if (!await approveRun('run the step “${node.name}”')) {
      return const ToolOutcome('the person declined the run', summary: 'Run declined', isError: true);
    }
    final problem = await controller.runStep(node);
    if (problem != null) {
      return ToolOutcome('could not run it: $problem', summary: 'Could not run “${node.name}”', isError: true);
    }
    final run = controller.lastRunOf(node);
    return ToolOutcome(
      _encode(run == null ? {'ran': false} : _stepJson(run, sample: 5)),
      summary: run?.error == null ? 'Ran “${node.name}”' : '“${node.name}” failed',
    );
  }

  ToolOutcome _stepOutput(JsonMap input) {
    final node = _node(input['node']);
    final run = controller.lastRunOf(node);
    if (run == null) return ToolOutcome('“${node.name}” did not run in the last run', summary: 'No output yet');
    return ToolOutcome(
      _encode(_stepJson(run, sample: asInt(input['limit'], 10))),
      summary: 'Read “${node.name}” output',
    );
  }

  JsonMap _runJson(ExecutionRecord? record) {
    if (record == null) return {'lastRun': null, 'note': 'not run yet in this editor'};
    final ran = record.runs.map((r) => r.nodeId).toSet();
    return {
      'status': record.status.name,
      if (record.error != null) 'error': record.error,
      'steps': [for (final r in record.runs) _stepJson(r, sample: 2)],
      'didNotRun': [
        for (final n in _wf.nodes)
          if (!ran.contains(n.id)) n.name,
      ],
    };
  }

  JsonMap _stepJson(NodeRunRecord r, {required int sample}) => {
    'step': r.name,
    'status': r.error == null ? 'ok' : 'error',
    if (r.error != null) 'error': r.error,
    'items': [for (final items in r.outputs) items.length],
    'output': [for (final items in r.outputs) items.take(sample).toList()],
  };

  static const _maxText = 12000;

  static String _encode(Object? value) {
    final s = jsonEncode(value);
    return s.length > _maxText ? '${s.substring(0, _maxText)}… (cut: ${s.length} characters in all)' : s;
  }
}
