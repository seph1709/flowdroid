import 'dart:convert';
import 'dart:io';

import '../core/json.dart';

/// A time Android (or the phone's battery manager) stopped FlowDroid's background service.
class Pause {
  const Pause(this.from, this.to);

  final DateTime from;
  final DateTime to;

  Duration get length => to.difference(from);
}

/// A heartbeat log: the background service records each minute it runs, so a
/// long silence between two beats shows the phone paused it. The setup screen
/// uses this to tell the user whether their settings actually work.
class BackgroundHealth {
  BackgroundHealth(Directory dataDir, {DateTime Function()? clock, Duration? Function()? uptime})
    : _file = File('${dataDir.path}/runtime/health.json'),
      _clock = clock ?? DateTime.now,
      _uptime = uptime ?? _systemUptime;

  /// How long the phone has been on; a silence longer than this was the phone being off.
  final Duration? Function() _uptime;

  static Duration? _systemUptime() {
    try {
      final secs = double.parse(File('/proc/uptime').readAsStringSync().split(' ').first);
      return Duration(milliseconds: (secs * 1000).round());
    } on Object {
      return null;
    }
  }

  /// The service beats once a minute; a silence longer than this is a pause.
  static const pauseAfter = Duration(minutes: 5);
  static const _keep = 50;

  final File _file;
  final DateTime Function() _clock;

  Future<JsonMap> _read() async {
    try {
      return asMap(jsonDecode(await _file.readAsString()));
    } on Object {
      return {};
    }
  }

  Future<void> _write(JsonMap data) async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(data));
    await temp.rename(_file.path);
  }

  /// Records that the service is running now.
  Future<void> beat() async {
    final data = await _read();
    final now = _clock();
    final last = data['lastBeat'] is int ? DateTime.fromMillisecondsSinceEpoch(data['lastBeat']! as int) : null;
    final pauses = asList(data['pauses']).toList();
    final up = _uptime();
    final silence = last == null ? Duration.zero : now.difference(last);
    // Switched off or restarted in between: that's not the phone pausing FlowDroid.
    final rebooted = up != null && up < silence;
    if (last != null && silence > pauseAfter && !rebooted) {
      pauses.add([last.millisecondsSinceEpoch, now.millisecondsSinceEpoch]);
      if (pauses.length > _keep) pauses.removeRange(0, pauses.length - _keep);
    }
    await _write({'lastBeat': now.millisecondsSinceEpoch, 'pauses': pauses});
  }

  /// Forgets the last beat, so turning "Keep running" back on doesn't count the off time as a pause.
  Future<void> restart() async {
    final data = await _read();
    await _write({'pauses': data['pauses'] ?? const []});
  }

  Future<DateTime?> lastBeat() async {
    final v = (await _read())['lastBeat'];
    return v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
  }

  /// Pauses that ended within [within] of now, newest first.
  Future<List<Pause>> recentPauses({Duration within = const Duration(hours: 24)}) async {
    final now = _clock();
    return [
      for (final p in asList((await _read())['pauses']).reversed)
        if (p is List && p.length == 2 && p[0] is int && p[1] is int)
          Pause(DateTime.fromMillisecondsSinceEpoch(p[0] as int), DateTime.fromMillisecondsSinceEpoch(p[1] as int)),
    ].where((p) => now.difference(p.to) <= within).toList();
  }

  /// The service should be beating but hasn't for a while: it is paused right now.
  Future<bool> pausedNow() async {
    final last = await lastBeat();
    return last != null && _clock().difference(last) > pauseAfter;
  }
}
