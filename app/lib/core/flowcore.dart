import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'execution_state.dart';
import 'json.dart';
import 'node_catalog.dart';

typedef _CallNative = Pointer<Utf8> Function(Pointer<Utf8> request);
typedef _FreeNative = Void Function(Pointer<Utf8> response);
typedef _FreeDart = void Function(Pointer<Utf8> response);

/// An error reported by the Rust core, e.g. `ExpressionError: unknown variable $x`.
class FlowCoreException implements Exception {
  const FlowCoreException(this.message);

  final String message;

  /// The part before the first colon: `InputError`, `ExpressionError`, `NodeError`, `CronError`.
  String get kind => message.split(':').first;

  @override
  String toString() => message;
}

/// The workflow core (Rust, `core/flowcore-engine`) loaded through `dart:ffi`.
///
/// Every call is synchronous and fast (microseconds to a few milliseconds),
/// so it runs on the calling isolate.
class FlowCore {
  FlowCore._(DynamicLibrary lib)
    : _call = lib.lookupFunction<_CallNative, _CallNative>('flowcore_call'),
      _free = lib.lookupFunction<_FreeNative, _FreeDart>('flowcore_free');

  /// Opens the library: bundled `libflowcore_ffi.so` on Android, or [path] (tests on the host).
  factory FlowCore.open({String? path}) {
    final location = path ?? (Platform.isAndroid ? 'libflowcore_ffi.so' : _hostLibraryPath());
    return FlowCore._(DynamicLibrary.open(location));
  }

  static FlowCore? _shared;

  /// The process-wide instance.
  static FlowCore get shared => _shared ??= FlowCore.open();

  final _CallNative _call;
  final _FreeDart _free;

  static String _hostLibraryPath() =>
      Platform.environment['FLOWCORE_LIB'] ?? '../core/target/release/libflowcore_ffi.so';

  Object? _invoke(String fn, List<Object?> args) {
    final request = jsonEncode({'fn': fn, 'args': args}).toNativeUtf8();
    try {
      final response = _call(request);
      if (response == nullptr) throw const FlowCoreException('InternalError: no response');
      try {
        final decoded = asMap(jsonDecode(response.toDartString()));
        final error = decoded['error'];
        if (error is String) throw FlowCoreException(error);
        return decoded['ok'];
      } finally {
        _free(response);
      }
    } finally {
      malloc.free(request);
    }
  }

  /// Renders a `{{ }}` template against [context]; returns the typed result.
  Object? evaluateTemplate(String template, JsonMap context) =>
      _invoke('evaluateTemplate', [template, jsonEncode(context)]);

  /// Problems that would stop the workflow from running; empty when it looks fine.
  List<String> validateWorkflow(JsonMap workflow) =>
      asList(_invoke('validateWorkflow', [jsonEncode(workflow)])).whereType<String>().toList();

  /// Every node type the editor can offer.
  List<NodeType> nodeCatalog() => asMapList(_invoke('nodeCatalog', const [])).map(NodeType.fromJson).toList();

  ExecutionState startExecution(String workflowJson, String triggerNodeId, List<JsonMap> items, DateTime now) =>
      _state(_invoke('startExecution', [workflowJson, triggerNodeId, jsonEncode(items), _ms(now)]));

  ExecutionState resumeExecution(String workflowJson, ExecutionState state, JsonMap result, DateTime now) =>
      _state(_invoke('resumeExecution', [workflowJson, state.raw, jsonEncode(result), _ms(now)]));

  /// The next time [cron] fires after [after], for a clock [utcOffset] ahead of UTC; null if never.
  DateTime? nextCronRun(String cron, DateTime after, Duration utcOffset) {
    final ms = asDouble(_invoke('nextCronRun', [cron, _ms(after), utcOffset.inMinutes.toDouble()]), -1);
    return ms < 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
  }

  static double _ms(DateTime t) => t.millisecondsSinceEpoch.toDouble();

  static ExecutionState _state(Object? decoded) => ExecutionState(asMap(decoded));
}
