import '../../core/json.dart';
import '../../core/param_helpers.dart';

/// One short line saying when a workflow runs, e.g. "Every 15 min" or "On SMS from +1555".
String triggerSummary(String? type, JsonMap? params) {
  final p = params ?? const <String, Object?>{};
  String filtered(String base, String key) {
    final v = asString(p[key]).trim();
    return v.isEmpty ? base : '$base ($v)';
  }

  return switch (type) {
    null => 'No trigger yet',
    'trigger.manual' => 'Run manually',
    'trigger.schedule' =>
      asString(p['mode']) == 'cron'
          ? (describeCron(asString(p['cron'])) ?? 'Custom schedule')
          : 'Every ${asDouble(p['minutes'], 15).round()} min',
    'trigger.webhook' => '/webhook/${asString(p['path'])}',
    'trigger.mcp' => 'MCP tool ${asString(p['name'], 'my_tool')}',
    'trigger.calendar' => _calendarSummary(p),
    'trigger.telegram' => 'On Telegram messages',
    'trigger.subworkflow' => 'Called by other workflows',
    'trigger.error' => 'When a workflow fails',
    'trigger.sms' => filtered('On SMS', 'from'),
    'trigger.notification' => filtered('On notifications', 'app'),
    'trigger.phone' => 'On ${_words(asString(p['event'], 'powerConnected'))}',
    'trigger.place' => asString(p['event'], 'enter') == 'leave' ? 'When leaving a place' : 'When arriving at a place',
    'trigger.share' => 'When shared to FlowDroid',
    'trigger.tile' => 'From the Quick Settings tile',
    'trigger.rss' => 'New posts, every ${asDouble(p['minutes'], 15).round()} min',
    'trigger.email' => 'New email, every ${asDouble(p['minutes'], 5).round()} min',
    _ => 'Run manually',
  };
}

/// `powerConnected` → `power connected`.
String _words(String id) => id.replaceAllMapped(RegExp('([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]!.toLowerCase()}');

/// "5 min before events start", "When events end".
String _calendarSummary(Map<String, Object?> p) {
  final minutes = asDouble(p['minutes'], 5).round();
  final end = asString(p['event'], 'start') == 'end';
  final when = minutes == 0
      ? (end ? 'When events end' : 'When events start')
      : (end ? '$minutes min after events end' : '$minutes min before events start');
  final title = asString(p['contains']).trim();
  return title.isEmpty ? when : '$when · “$title”';
}
