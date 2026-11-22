import 'json.dart';

enum ParamKind {
  text,
  number,
  boolean,
  select,
  json,
  conditions,
  rules,
  fields,
  keyValues,
  credential,
  workflow,
  code,
  tools,
}

enum NodeGroup { trigger, flow, data, network, android, ai, communication, database, productivity, system }

class ParamSpec {
  ParamSpec.fromJson(JsonMap json)
    : key = asString(json['key']),
      label = asString(json['label']),
      kind = ParamKind.values.byName(asString(json['kind'], 'text')),
      defaultValue = json['default'],
      options = asList(json['options']).whereType<String>().toList(),
      hint = json['hint'] as String?;

  final String key;
  final String label;
  final ParamKind kind;
  final Object? defaultValue;
  final List<String> options;
  final String? hint;
}

/// A node type as the core's catalog describes it.
class NodeType {
  NodeType.fromJson(JsonMap json)
    : type = asString(json['type']),
      label = asString(json['label']),
      group = NodeGroup.values.byName(asString(json['group'], 'flow')),
      description = asString(json['description']),
      inputs = asInt(json['inputs']),
      outputs = json['outputs'] == null ? null : asList(json['outputs']).whereType<String>().toList(),
      params = asMapList(json['params']).map(ParamSpec.fromJson).toList();

  final String type;
  final String label;
  final NodeGroup group;
  final String description;
  final int inputs;

  /// Output labels; null when they come from the Switch node's rules.
  final List<String>? outputs;
  final List<ParamSpec> params;

  bool get isTrigger => group == NodeGroup.trigger;

  /// Output labels for a node with these parameters.
  List<String> outputLabels(JsonMap params) {
    final fixed = outputs;
    if (fixed != null) return fixed;
    final rules = asList(params['rules']).length;
    return [for (var i = 0; i < rules; i++) 'rule ${i + 1}', if (params['fallback'] == true) 'fallback'];
  }

  JsonMap defaultParams() => {for (final p in params) p.key: p.defaultValue};
}

/// Condition operators understood by If, Filter and Switch (matches `conditions.ts`).
const conditionOperators = [
  'equals',
  'notEquals',
  'contains',
  'notContains',
  'startsWith',
  'endsWith',
  'gt',
  'gte',
  'lt',
  'lte',
  'isEmpty',
  'isNotEmpty',
  'isTrue',
  'isFalse',
];

/// Operators that ignore the right-hand side.
const unaryOperators = {'isEmpty', 'isNotEmpty', 'isTrue', 'isFalse'};
