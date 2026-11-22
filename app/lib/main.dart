import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'app_services.dart';
import 'runtime/background.dart';
import 'runtime/runtime_host.dart';
import 'ui/home/home_page.dart';
import 'ui/launch_handler.dart';
import 'ui/services_scope.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices.create(await getApplicationDocumentsDirectory());
  final runtime = RuntimeHost(services);
  runApp(FlowDroidApp(services: services, runtime: runtime));
  unawaited(_startRuntime(runtime));
}

/// Starts what runs workflows without a tap: the keep-alive service or the
/// in-app runtime, plus the WorkManager fallback scheduler.
Future<void> _startRuntime(RuntimeHost runtime) async {
  await runtime.start();
  try {
    await registerBackgroundScheduler();
  } on Exception catch (e) {
    debugPrint('Background scheduler unavailable: $e');
  }
}

class FlowDroidApp extends StatelessWidget {
  const FlowDroidApp({super.key, required this.services, required this.runtime});

  final AppServices services;
  final RuntimeHost runtime;

  @override
  Widget build(BuildContext context) {
    return ServicesScope(
      services: services,
      runtime: runtime,
      // Keeps the service's isolate connected to the UI while the app is open.
      child: WithForegroundTask(
        child: ListenableBuilder(
          listenable: services.appearance,
          builder: (context, _) => MaterialApp(
            title: 'FlowDroid',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: services.appearance.mode,
            home: const LaunchHandler(child: HomePage()),
          ),
        ),
      ),
    );
  }
}
