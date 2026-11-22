import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../app_services.dart';

const schedulerTask = 'flowdroid.scheduler.tick';

/// Entry point WorkManager calls in a background isolate.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    if (task != schedulerTask) return true;
    WidgetsFlutterBinding.ensureInitialized();
    // Plugins (notifications, HTTP, battery, ...) must be registered in this isolate too.
    DartPluginRegistrant.ensureInitialized();
    // The keep-alive service checks schedules every minute itself; ticking here too could double-fire.
    if (await FlutterForegroundTask.isRunningService) return true;
    final services = AppServices.create(await getApplicationDocumentsDirectory(), interactive: false);
    // Watchdog: if "Keep running" is on but the phone stopped the service, bring it back.
    // (The restart does nothing when the user turned it off.)
    await services.phone.wakeService();
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await FlutterForegroundTask.isRunningService) return true;
    }
    await services.tick();
    return true;
  });
}

/// Registers the periodic background tick (Android allows at most every 15 minutes).
/// It is the fallback when "Keep running" is off, and the watchdog that restarts
/// the service if the phone stopped it.
Future<void> registerBackgroundScheduler() async {
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    schedulerTask,
    schedulerTask,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
