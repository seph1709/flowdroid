import 'dart:io';

import 'package:flowdroid/core/flowcore.dart';
import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/data/repository.dart';
import 'package:flowdroid/runtime/effects.dart';

/// The host build of the Rust core: `cargo build --release -p flowcore-ffi` in `core/`.
final core = FlowCore.open(path: '../core/target/release/libflowcore_ffi.so');

/// A repository in a fresh temporary directory.
Future<Repository> tempRepository() async => Repository(await Directory.systemTemp.createTemp('flowdroid_test'));

/// Effects that record what was asked and answer with canned results.
class FakeEffects extends EffectDispatcher {
  FakeEffects([Map<String, JsonMap> answers = const {}]) : _answers = answers;

  final Map<String, JsonMap> _answers;
  final performed = <JsonMap>[];

  @override
  Map<String, Future<JsonMap> Function(JsonMap effect)> get handlers => {
    for (final type in [
      'http',
      'wait',
      'notify',
      'speak',
      'vibrate',
      'openUrl',
      'clipboardWrite',
      'clipboardRead',
      'battery',
      'location',
      'table',
      'command',
    ])
      type: (effect) async {
        performed.add(effect);
        return _answers[type] ?? const {};
      },
  };
}
