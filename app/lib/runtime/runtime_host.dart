import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../app_services.dart';
import 'keep_alive_service.dart';

/// Decides where workflows run automatically.
///
/// With "Keep running" on, the [KeepAliveService] owns the webhook server and
/// the scheduler, in its own isolate. With it off, they run inside the app
/// while it is open (and WorkManager checks schedules every ~15 minutes).
/// Only one of the two runs at a time, so the webhook port is never taken twice
/// and a schedule never fires twice.
class RuntimeHost extends ChangeNotifier {
  RuntimeHost(this.services);

  final AppServices services;
  Timer? _ticker;
  bool _keepRunning = false;

  bool get keepRunning => _keepRunning;

  Future<void> start() async {
    KeepAliveService.init();
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_onServiceData);
    _keepRunning = await KeepAliveService.isRunning;
    if (!_keepRunning) await _startInProcess();
    notifyListeners();
  }

  /// Turns the background service on or off; returns false if Android refused to start it.
  Future<bool> setKeepRunning(bool enabled) async {
    if (enabled == _keepRunning) return true;
    if (enabled) {
      await _stopInProcess();
      // The time it was off is not a pause by Android.
      await services.health.restart();
      final started = await KeepAliveService.start();
      if (!started) {
        await _startInProcess();
        return false;
      }
    } else {
      await KeepAliveService.stop();
      await services.phone.setWakeAlarm(null);
      await _startInProcess();
    }
    _keepRunning = enabled;
    notifyListeners();
    return true;
  }

  Future<void> _startInProcess() async {
    try {
      await services.webhooks.start();
    } on Exception catch (e) {
      debugPrint('Webhook server did not start: $e');
    }
    _ticker ??= Timer.periodic(const Duration(minutes: 1), (_) => services.tick());
    services.startListeners();
  }

  Future<void> _stopInProcess() async {
    _ticker?.cancel();
    _ticker = null;
    services.stopListeners();
    await services.webhooks.stop();
  }

  void _onServiceData(Object data) {
    if (data == dataChangedMessage) services.repository.reload();
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onServiceData);
    _ticker?.cancel();
    super.dispose();
  }
}
