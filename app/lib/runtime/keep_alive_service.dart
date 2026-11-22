import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';

import '../app_services.dart';

/// Message the service sends the UI after it ran something, so screens reload from disk.
const dataChangedMessage = 'data-changed';

/// A foreground service that keeps workflows running when the app is closed:
/// it owns the webhook server and checks schedules every minute.
///
/// It survives the app being swiped away, restarts after a reboot or an app
/// update, and holds a wake lock so timers keep running while the screen is off.
/// Android requires the permanent notification that comes with it.
abstract final class KeepAliveService {
  static const _serviceId = 4242;
  static const _tickInterval = Duration(minutes: 1);

  /// Longest time between wake-up alarms, even with no schedule due.
  static const watchdogInterval = Duration(minutes: 15);

  /// Must run before any other call, in every isolate that uses the service.
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'flowdroid_runtime',
        channelName: 'Background runtime',
        channelDescription: 'Shown while FlowDroid keeps your workflows running',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(_tickInterval.inMilliseconds),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Starts the service; returns false if Android refused.
  static Future<bool> start() async {
    if (await isRunning) return true;
    final result = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: 'FlowDroid is running',
      notificationText: 'Schedules and webhooks are active',
      callback: serviceEntryPoint,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    await FlutterForegroundTask.stopService();
  }
}

/// Entry point of the service's own isolate.
@pragma('vm:entry-point')
void serviceEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_RuntimeTaskHandler());
}

class _RuntimeTaskHandler extends TaskHandler {
  AppServices? _services;
  bool _ticking = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final services = AppServices.create(await getApplicationDocumentsDirectory(), interactive: false);
    _services = services;
    services.repository.addListener(() => FlutterForegroundTask.sendDataToMain(dataChangedMessage));
    try {
      await services.webhooks.start();
    } on Exception catch (e) {
      debugPrint('Webhook server did not start in the service: $e');
    }
    services.startListeners();
    await _tick();
  }

  @override
  void onRepeatEvent(DateTime timestamp) => unawaited(_tick());

  /// One scheduler pass; skipped while the previous one is still running a long workflow.
  Future<void> _tick() async {
    final services = _services;
    if (services == null || _ticking) return;
    _ticking = true;
    try {
      await services.health.beat();
      await services.tick();
      await _setWakeAlarm(services);
      await _updateNotification(services);
    } finally {
      _ticking = false;
    }
  }

  /// The next wake-up: the next schedule, or the watchdog interval, whichever is first.
  /// If the phone freezes FlowDroid, the alarm still fires and brings it back.
  Future<void> _setWakeAlarm(AppServices services) async {
    final watchdog = DateTime.now().add(KeepAliveService.watchdogInterval);
    final due = await services.scheduler.nextDue();
    await services.phone.setWakeAlarm(due != null && due.isBefore(watchdog) ? due : watchdog);
  }

  Future<void> _updateNotification(AppServices services) async {
    final active = (await services.repository.workflows()).where((w) => w.active).length;
    final webhooks = services.webhooks.isRunning ? 'webhooks on :${services.webhooks.port}' : 'webhooks off';
    await FlutterForegroundTask.updateService(
      notificationTitle: 'FlowDroid is running',
      notificationText: '$active active workflow${active == 1 ? '' : 's'} · $webhooks',
    );
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _services?.stopListeners();
    await _services?.webhooks.stop();
  }
}
