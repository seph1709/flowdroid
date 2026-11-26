// Renders the app's real screens to PNG for the README preview.
//
//   cd app
//   flutter test screenshots --update-goldens
//
// Writes screenshots/out/*.png (a 412×892 phone at 3× density). Not part of the
// normal test run, since it lives outside test/.
import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/app_services.dart';
import 'package:flowdroid/core/execution_state.dart';
import 'package:flowdroid/core/flowcore.dart';
import 'package:flowdroid/core/json.dart';
import 'package:flowdroid/core/workflow.dart';
import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/data/execution_record.dart';
import 'package:flowdroid/data/repository.dart';
import 'package:flowdroid/data/templates.dart';
import 'package:flowdroid/runtime/effects.dart';
import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flowdroid/runtime/runtime_host.dart';
import 'package:flowdroid/ui/editor/editor_page.dart';
import 'package:flowdroid/ui/home/home_page.dart';
import 'package:flowdroid/ui/services_scope.dart';
import 'package:flowdroid/ui/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _phone = Size(412, 892);

/// Shows the app as it looks with "Keep running" on, so no setup hint covers the list.
class _ShowcaseRuntime extends RuntimeHost {
  _ShowcaseRuntime(super.services);

  @override
  bool get keepRunning => true;
}

/// Sample workflows and runs held in memory, answered synchronously, since file
/// reads never finish under the widget test's fake clock.
class _ShowcaseRepository extends Repository {
  _ShowcaseRepository(super.root);

  final _workflows = <Workflow>[];
  final _latest = <String, ExecutionRecord>{};

  @override
  Future<List<Workflow>> workflows() => SynchronousFuture(_workflows.reversed.toList());

  @override
  Future<ExecutionRecord?> latestExecution(String workflowId) => SynchronousFuture(_latest[workflowId]);

  @override
  Future<List<ExecutionRecord>> executions(String workflowId) =>
      SynchronousFuture([?_latest[workflowId]]);

  @override
  Future<void> saveWorkflow(Workflow wf) {
    _workflows.add(wf);
    return SynchronousFuture(null);
  }

  @override
  Future<void> saveExecution(ExecutionRecord record) {
    _latest[record.workflowId] = record;
    return SynchronousFuture(null);
  }
}

class _NoEffects implements EffectHandler {
  @override
  Future<JsonMap> perform(JsonMap effect, {WebhookResponder? respond}) async => const {};
}

Future<void> _loadFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(entry['family']! as String);
    for (final font in (entry['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

void main() {
  late AppServices services;

  setUpAll(() async {
    await _loadFonts();
    final dir = await Directory.systemTemp.createTemp('flowdroid_shots');
    services = AppServices(
      core: FlowCore.open(path: Platform.environment['FLOWCORE_LIB'] ?? '../core/target/release/flowcore_ffi.dll'),
      repository: _ShowcaseRepository(dir),
      credentials: CredentialStore(),
      linux: LinuxRuntime(dir),
      dataDir: dir,
      effects: _NoEffects(),
    );
    final repo = services.repository;
    final now = DateTime.now();
    // Saved oldest first, so the list (newest first) reads in this order.
    final picks = <(String, bool, Duration?, bool)>[
      ('Daily server check', false, null, true),
      ('Save shared text to my notes', true, const Duration(days: 1), true),
      ('Low battery alert', true, const Duration(hours: 3), true),
      ('Forward SMS codes to Telegram', true, const Duration(minutes: 42), true),
      ('Morning quote', true, const Duration(hours: 2), false),
      ('Telegram AI assistant', true, const Duration(minutes: 5), true),
    ];
    for (final (title, active, ranAgo, ok) in picks) {
      final wf = templates.firstWhere((t) => t.title == title).build()..active = active;
      await repo.saveWorkflow(wf);
      if (ranAgo != null) {
        final at = now.subtract(ranAgo);
        await repo.saveExecution(
          ExecutionRecord(
            id: 'ex_${wf.id}',
            workflowId: wf.id,
            workflowName: wf.name,
            mode: TriggerMode.manual,
            status: ok ? ExecutionStatus.success : ExecutionStatus.error,
            startedAt: at,
            finishedAt: at.add(const Duration(seconds: 2)),
            error: ok ? null : 'HTTP 503',
            runs: const [],
          ),
        );
      }
    }
  });

  Future<void> shoot(WidgetTester tester, String name, Widget home, {Future<void> Function()? then}) async {
    tester.view
      ..physicalSize = _phone * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ServicesScope(
        services: services,
        runtime: _ShowcaseRuntime(services),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: home,
        ),
      ),
    );
    // File reads finish outside the fake clock.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    if (then != null) {
      await then();
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('out/$name.png'));
  }

  testWidgets('home', (tester) => shoot(tester, 'home', const HomePage()));

  testWidgets('new workflow', (tester) async {
    await shoot(
      tester,
      'new',
      const HomePage(),
      then: () async {
        await tester.tap(find.text('New workflow').last);
      },
    );
  });

  testWidgets('editor', (tester) async {
    final wf = (await services.repository.workflows()).firstWhere(
      (w) => w.name == 'Telegram AI assistant',
    );
    await shoot(tester, 'editor', EditorPage(workflow: wf));
  });
}
