import 'dart:async';
import 'dart:io';

import 'package:phone_bridge/phone_bridge.dart';

import 'core/flowcore.dart';
import 'core/json.dart';
import 'core/node_catalog.dart';
import 'data/appearance.dart';
import 'data/credentials.dart';
import 'data/repository.dart';
import 'runtime/agent_tools.dart';
import 'runtime/background_health.dart';
import 'runtime/code_runner.dart';
import 'runtime/credential_resolver.dart';
import 'runtime/device_effects.dart';
import 'runtime/effects.dart';
import 'runtime/email_service.dart';
import 'runtime/feeds.dart';
import 'runtime/file_store.dart';
import 'runtime/file_effect.dart';
import 'runtime/http_effect.dart';
import 'runtime/knowledge_base.dart';
import 'runtime/linux/linux_runtime.dart';
import 'runtime/phone/phone_events.dart';
import 'runtime/runner.dart';
import 'runtime/scheduler.dart';
import 'runtime/speech.dart';
import 'runtime/table_effect.dart';
import 'runtime/telegram_poller.dart';
import 'runtime/text_extractor.dart';
import 'runtime/trigger_pollers.dart';
import 'runtime/webhook_server.dart';

/// Wires the app's long-lived objects together; one instance per isolate.
class AppServices {
  AppServices({
    required this.core,
    required this.repository,
    required this.credentials,
    required this.linux,
    required this.dataDir,
    required EffectHandler effects,
    PhoneBridge? phone,
    FeedReader? feeds,
    EmailService? email,
    Speech? speech,
  }) : catalog = core.nodeCatalog(),
       phone = phone ?? PhoneBridge(),
       runner = WorkflowRunner(core: core, effects: effects, repository: repository) {
    this.speech = speech ?? Speech(credentials: credentials, phone: this.phone, dataDir: dataDir);
    scheduler = Scheduler(core: core, repository: repository, runner: runner);
    webhooks = WebhookServer(repository: repository, runner: runner, credentials: credentials);
    telegram = TelegramPoller(repository: repository, runner: runner, credentials: credentials);
    phoneEvents = PhoneEvents(
      dataDir: dataDir,
      repository: repository,
      runner: runner,
      bridge: this.phone,
      onTick: tick,
    );
    health = BackgroundHealth(dataDir);
    pollers = TriggerPollers(
      repository: repository,
      runner: runner,
      feeds: feeds ?? FeedReader(),
      email: email ?? EmailService(credentials),
    );
  }

  /// [interactive] is false in background isolates, where no permission prompt can be shown.
  factory AppServices.create(Directory dataDir, {FlowCore? core, EffectHandler? effects, bool interactive = true}) {
    final credentials = CredentialStore();
    final linux = LinuxRuntime(dataDir);
    final tables = TableEffect(dataDir);
    final phone = PhoneBridge();
    final feeds = FeedReader();
    final email = EmailService(credentials, files: FileStore(dataDir));
    final speech = Speech(credentials: credentials, phone: phone, dataDir: dataDir);
    final knowledge = KnowledgeBase(dataDir: dataDir, credentials: credentials);
    late final AppServices services;
    Future<List<JsonMap>> callWorkflow(String id, List<JsonMap> items) => services.runner.runSubWorkflow(id, items);

    services = AppServices(
      linux: linux,
      core: core ?? FlowCore.shared,
      repository: Repository(dataDir),
      credentials: credentials,
      dataDir: dataDir,
      phone: phone,
      feeds: feeds,
      email: email,
      speech: speech,
      effects:
          effects ??
          DeviceEffects(
            interactive: interactive,
            phone: phone,
            http: HttpEffect(credentials: CredentialResolver(credentials), files: FileStore(dataDir)),
            tables: tables,
            linux: linux,
            extra: {
              'code': CodeRunner(linux).call,
              'workflow': (effect) => callWorkflows(effect, callWorkflow),
              'tools': AgentTools(linux: linux, tables: tables, callWorkflow: callWorkflow).call,
              'sms': (effect) => sendSms(effect, phone),
              'speak': speech.call,
              'knowledge': knowledge.call,
              'extract': TextExtractor(files: FileStore(dataDir), linux: linux).call,
              'email': email.call,
              'rss': feeds.call,
              'file': FileEffect(Directory('${dataDir.path}/files')).call,
            },
          ),
    );
    return services;
  }

  final FlowCore core;
  final Repository repository;
  final CredentialStore credentials;
  final LinuxRuntime linux;
  final Directory dataDir;
  final PhoneBridge phone;
  final List<NodeType> catalog;
  final WorkflowRunner runner;
  late final Scheduler scheduler;
  late final WebhookServer webhooks;
  late final TelegramPoller telegram;
  late final PhoneEvents phoneEvents;
  late final TriggerPollers pollers;

  /// Light, dark or system theme (only the app's UI uses it).
  late final Appearance appearance = Appearance(dataDir)..load();

  /// Knowledge bases (RAG) stored on the phone.
  late final KnowledgeBase knowledge = KnowledgeBase(dataDir: dataDir, credentials: credentials);

  /// Phone and cloud voices for Speak Text, and the voice picker.
  late final Speech speech;

  /// When the background service last ran, and when Android paused it.
  late final BackgroundHealth health;

  Future<void>? _tickRunning;

  NodeType? nodeType(String type) {
    for (final t in catalog) {
      if (t.type == type) return t;
    }
    return null;
  }

  /// Starts the triggers that listen continuously (Telegram, phone events).
  void startListeners() {
    telegram.start();
    phoneEvents.start();
  }

  void stopListeners() {
    telegram.stop();
    phoneEvents.stop();
  }

  /// The once-a-minute work: schedules, then Place, RSS and Email checks.
  /// The wake-up alarm, the service timer and WorkManager can all ask for a tick;
  /// one at a time, so a schedule never fires twice for the same slot.
  Future<void> tick() async {
    final running = _tickRunning;
    if (running != null) return running;
    final work = () async {
      await scheduler.tick();
      await pollers.tick();
    }();
    _tickRunning = work;
    try {
      await work;
    } finally {
      _tickRunning = null;
    }
  }
}

/// The `workflow` effect: runs the called workflow once per entry of `runs`.
Future<JsonMap> callWorkflows(JsonMap effect, WorkflowCaller call) async {
  final id = asString(effect['workflowId']);
  final runs = asList(effect['runs']).map(asMapList).toList();
  if (effect['wait'] == false) {
    for (final items in runs) {
      unawaited(call(id, items).then((_) {}, onError: (Object _) {}));
    }
    return const {};
  }
  return {
    'outputs': [for (final items in runs) await call(id, items)],
  };
}

/// The `sms` effect: sends each message, stopping at the first failure.
Future<JsonMap> sendSms(JsonMap effect, PhoneBridge phone) async {
  for (final m in asMapList(effect['messages'])) {
    final error = await phone.sendSms(asString(m['to']), asString(m['text']));
    if (error != null) return {'error': error};
  }
  return const {};
}
