import '../core/json.dart';
import '../core/layout.dart';
import '../core/workflow.dart';

/// Whether [json] looks like a workflow exported from n8n (connections keyed by node name).
bool isN8nWorkflow(JsonMap json) =>
    json['connections'] is Map || asMapList(json['nodes']).any((n) => n.containsKey('typeVersion'));

/// What an n8n import produced, and which nodes had no FlowDroid counterpart.
class N8nImport {
  const N8nImport(this.workflow, this.unsupported);

  final Workflow workflow;

  /// n8n node types that became placeholder (No Op) steps.
  final List<String> unsupported;
}

/// Converts an n8n workflow export into a FlowDroid workflow, best effort.
///
/// Node types FlowDroid has are mapped with their main parameters; credentials
/// must be chosen again. Other nodes become No Op steps named after what they were.
N8nImport importN8n(JsonMap json) {
  final unsupported = <String>[];
  final ids = <String, String>{};
  final nodes = <WorkflowNode>[];
  final usedNames = <String>{};
  for (final n in asMapList(json['nodes'])) {
    final type = asString(n['type']);
    final p = asMap(n['parameters']);
    final mapped = _mapNode(type, p);
    if (mapped == null) unsupported.add(type);
    final (flowType, params) = mapped ?? ('core.noop', <String, Object?>{});
    final id = newId('n_');
    final original = asString(n['name'], type.split('.').last);
    var name = mapped == null ? '$original (not supported)' : original;
    while (usedNames.contains(name)) {
      name = '$name 2';
    }
    usedNames.add(name);
    ids[original] = id;
    nodes.add(WorkflowNode(id: id, name: name, type: flowType, params: params, disabled: asBool(n['disabled'])));
  }
  final connections = <Connection>[];
  asMap(json['connections']).forEach((from, outputs) {
    final fromId = ids[from];
    if (fromId == null) return;
    final main = asList(asMap(outputs)['main']);
    for (final (output, targets) in main.indexed) {
      for (final t in asMapList(targets)) {
        final toId = ids[asString(t['node'])];
        if (toId != null) connections.add(Connection(from: fromId, output: output, to: toId, input: asInt(t['index'])));
      }
    }
  });
  final wf = Workflow(
    id: newId('wf_'),
    name: asString(json['name'], 'Imported workflow'),
    nodes: nodes,
    connections: connections,
  );
  layoutVertically(wf, (n) => n.type.startsWith('trigger.'));
  return N8nImport(wf, unsupported);
}

/// `={{ $json.a }}` → `{{ $json.a }}`, and n8n's `$('Name').item.json` → `$node["Name"].json`.
Object? _value(Object? v) {
  if (v is! String) return v;
  var s = v.startsWith('=') ? v.substring(1) : v;
  s = s.replaceAllMapped(
    RegExp(r'''\$\(\s*['"]([^'"]+)['"]\s*\)\.(?:item|first\(\)|last\(\))\.json'''),
    (m) => '\$node["${m[1]}"].json',
  );
  return s;
}

String _text(Object? v, [String fallback = '']) => asString(_value(v), fallback);

const _operators = {
  'equals': 'equals',
  'notEquals': 'notEquals',
  'contains': 'contains',
  'notContains': 'notContains',
  'startsWith': 'startsWith',
  'endsWith': 'endsWith',
  'gt': 'gt',
  'gte': 'gte',
  'lt': 'lt',
  'lte': 'lte',
  'empty': 'isEmpty',
  'notEmpty': 'isNotEmpty',
  'true': 'isTrue',
  'false': 'isFalse',
};

/// n8n's v2 conditions (`conditions.conditions[]`) as FlowDroid condition rows.
List<JsonMap> _conditions(JsonMap p) => [
  for (final c in asMapList(asMap(p['conditions'])['conditions']))
    {
      'left': _value(c['leftValue']),
      'op': _operators[asString(asMap(c['operator'])['operation'])] ?? 'equals',
      'right': _value(c['rightValue']),
    },
];

String _combine(JsonMap p) => asString(asMap(p['conditions'])['combinator'], 'and') == 'or' ? 'or' : 'and';

(String, JsonMap)? _mapNode(String type, JsonMap p) {
  final short = type.split('.').last;
  switch (short) {
    case 'manualTrigger':
      return ('trigger.manual', {});
    case 'scheduleTrigger' || 'cron':
      final rule = asMapList(asMap(p['rule'])['interval']).firstOrNull ?? const {};
      final field = asString(rule['field'], 'minutes');
      if (field == 'cronExpression') return ('trigger.schedule', {'mode': 'cron', 'cron': _text(rule['expression'])});
      final minutes = switch (field) {
        'hours' => asInt(rule['hoursInterval'], 1) * 60,
        'days' => asInt(rule['daysInterval'], 1) * 24 * 60,
        _ => asInt(rule['minutesInterval'], 15),
      };
      return ('trigger.schedule', {'mode': 'interval', 'minutes': minutes});
    case 'webhook':
      return ('trigger.webhook', {'path': _text(p['path'], 'my-hook'), 'method': _text(p['httpMethod'], 'GET')});
    case 'executeWorkflowTrigger':
      return ('trigger.subworkflow', {});
    case 'errorTrigger':
      return ('trigger.error', {});
    case 'rssFeedReadTrigger':
      return ('trigger.rss', {'url': _text(p['feedUrl']), 'minutes': 15});
    case 'emailReadImap':
      return ('trigger.email', {'mailbox': _text(p['mailbox'], 'INBOX')});
    case 'telegramTrigger':
      return ('trigger.telegram', {});
    case 'httpRequest':
      return (
        'http.request',
        {
          'method': _text(p['method'], 'GET'),
          'url': _text(p['url']),
          'headers': [
            for (final h in asMapList(asMap(p['headerParameters'])['parameters']))
              {'name': _value(h['name']), 'value': _value(h['value'])},
          ],
          'body': _value(p['jsonBody'] ?? p['body'] ?? ''),
        },
      );
    case 'if':
      return ('core.if', {'conditions': _conditions(p), 'combine': _combine(p)});
    case 'filter':
      return ('core.filter', {'conditions': _conditions(p), 'combine': _combine(p)});
    case 'switch':
      return (
        'core.switch',
        {
          'rules': [for (final rule in asMapList(asMap(p['rules'])['values'])) ..._conditions(rule).take(1)],
          'fallback': asString(asMap(p['options'])['fallbackOutput']) == 'extra',
        },
      );
    case 'merge':
      final mode = switch (asString(p['mode'])) {
        'combine' || 'combineByPosition' => 'combineByIndex',
        'chooseBranch' => 'chooseBranch',
        _ => 'append',
      };
      return ('core.merge', {'mode': mode});
    case 'set':
      final assignments = asMapList(asMap(p['assignments'])['assignments']);
      final legacy = asMap(p['values']).values.expand(asMapList);
      return (
        'core.set',
        {
          'fields': [
            for (final a in [...assignments, ...legacy]) {'name': _value(a['name']), 'value': _value(a['value'])},
          ],
        },
      );
    case 'code':
      final python = asString(p['language']) == 'pythonNative' || asString(p['language']) == 'python';
      final code = python ? asString(p['pythonCode']) : asString(p['jsCode']);
      return (
        'core.code',
        {
          'language': python ? 'python' : 'javascript',
          'mode': asString(p['mode']) == 'runOnceForEachItem' ? 'eachItem' : 'allItems',
          'code':
              '${python ? '#' : '//'} Imported from n8n: n8n uses \$input / \$json (or _input); here use items / item.\n$code',
        },
      );
    case 'noOp':
      return ('core.noop', {});
    case 'wait':
      final amount = asDouble(p['amount'], 1);
      final seconds = switch (asString(p['unit'], 'seconds')) {
        'minutes' => amount * 60,
        'hours' => amount * 3600,
        _ => amount,
      };
      return ('core.wait', {'seconds': seconds});
    case 'respondToWebhook':
      return ('core.respond', {'body': _value(p['responseBody'] ?? '{{ \$json }}')});
    case 'splitInBatches':
      return ('core.loop', {'batchSize': asInt(p['batchSize'], 1)});
    case 'executeWorkflow':
      return ('core.executeWorkflow', {});
    case 'splitOut':
      return ('core.splitOut', {'field': _text(p['fieldToSplitOut'])});
    case 'aggregate':
      return ('core.aggregate', {'field': _text(p['fieldToAggregate'])});
    case 'sort':
      return ('core.sort', {});
    case 'limit':
      return ('core.limit', {'max': asInt(p['maxItems'], 1)});
    case 'removeDuplicates':
      return ('core.removeDuplicates', {});
    case 'telegram':
      return ('telegram.send', {'chatId': _text(p['chatId']), 'text': _text(p['text'])});
    case 'discord':
      return ('discord.send', {'content': _text(p['content'] ?? p['text'])});
    case 'emailSend':
      return (
        'email.send',
        {'to': _text(p['toEmail']), 'subject': _text(p['subject']), 'text': _text(p['text'] ?? p['html'])},
      );
    case 'rssFeedRead':
      return ('rss.read', {'url': _text(p['url'])});
    case 'executeCommand':
      return ('system.command', {'target': 'ubuntu', 'command': _text(p['command'])});
    case 'readWriteFile':
      return ('files', {'path': _text(p['fileName'])});
    case 'googleSheets':
      return ('google.sheets', {});
    case 'gmail':
      return ('google.gmail', {'to': _text(p['sendTo']), 'subject': _text(p['subject']), 'body': _text(p['message'])});
    case 'googleCalendar':
      return ('google.calendar', {});
    case 'googleDrive':
      return ('google.drive', {});
    case 'notion':
      return ('db.notion', {});
    case 'airtable':
      return ('db.airtable', {});
    case 'supabase':
      return ('db.supabase', {'table': _text(p['tableId'])});
    case 'agent':
      return (
        'ai.agent',
        {'prompt': _text(p['text'], '{{ \$json.chatInput }}'), 'system': _text(asMap(p['options'])['systemMessage'])},
      );
    case 'openAi' || 'lmChatOpenAi' || 'chainLlm':
      return ('ai.chat', {'provider': 'openai', 'prompt': _text(p['text'] ?? p['prompt'])});
    case 'lmChatAnthropic':
      return ('ai.chat', {'provider': 'anthropic'});
    default:
      return null;
  }
}
