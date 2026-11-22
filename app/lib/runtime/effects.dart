import '../core/json.dart';

/// Sends the HTTP response for the webhook that started a run.
typedef WebhookResponder = Future<void> Function(int status, String contentType, Object? body);

/// Performs the side effects the core asks for (`pending.effect`) and returns
/// the result the core expects back. Implementations never throw: failures
/// become `{error: message}`, which the core turns into a node error.
abstract interface class EffectHandler {
  Future<JsonMap> perform(JsonMap effect, {WebhookResponder? respond});
}

/// Runs the handler for `effect.type`, turning exceptions into `{error}` results.
abstract class EffectDispatcher implements EffectHandler {
  /// Phone actions that should be quick: if one hangs (a permission dialog that
  /// can't show in the background, a plugin that never answers) the run fails
  /// with a clear error instead of waiting forever. Steps with their own timeouts
  /// (HTTP, Code, commands, AI, waits) aren't listed.
  static const quickLimits = {
    'notify': Duration(seconds: 30),
    'vibrate': Duration(seconds: 30),
    'openUrl': Duration(seconds: 30),
    'clipboardWrite': Duration(seconds: 30),
    'clipboardRead': Duration(seconds: 30),
    'battery': Duration(seconds: 30),
    'location': Duration(seconds: 60),
    'speak': Duration(minutes: 5),
    'table': Duration(seconds: 60),
    'sms': Duration(seconds: 60),
  };

  /// Handlers by effect type; each returns the result for the core.
  Map<String, Future<JsonMap> Function(JsonMap effect)> get handlers;

  @override
  Future<JsonMap> perform(JsonMap effect, {WebhookResponder? respond}) async {
    final type = asString(effect['type']);
    try {
      if (type == 'respond') return await _respond(effect, respond);
      final handler = handlers[type];
      if (handler == null) return {'error': 'this device cannot perform "$type"'};
      final limit = quickLimits[type];
      if (limit == null) return await handler(effect);
      return await handler(effect)
          .timeout(limit, onTimeout: () => {'error': 'the phone did not finish "$type" within ${limit.inSeconds} s'});
    } on Exception catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<JsonMap> _respond(JsonMap effect, WebhookResponder? respond) async {
    if (respond == null) return const {}; // Not started by a webhook: nothing to answer.
    await respond(asInt(effect['status'], 200), asString(effect['contentType'], 'application/json'), effect['body']);
    return const {};
  }
}
