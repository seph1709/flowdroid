/// Pickers and suggestions under parameters whose values people can't be
/// expected to know: apps, contacts, places, schedules, dates, model names,
/// IDs hidden in links, field names, Telegram chats.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:phone_bridge/phone_bridge.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/json.dart';
import '../../core/node_catalog.dart';
import '../../core/param_helpers.dart';
import '../../core/schedule_spec.dart';
import '../../core/workflow.dart';
import '../../runtime/mcp_client.dart';
import '../../runtime/speech.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import 'data_mapping.dart';
import 'editor_controller.dart';

/// Everything an assist needs: the node, the parameter and how to change values.
class AssistContext {
  const AssistContext({required this.controller, required this.node, required this.spec});

  final EditorController controller;
  final WorkflowNode node;
  final ParamSpec spec;

  Object? get value => node.params[spec.key] ?? spec.defaultValue;
  String get text => switch (value) {
    null => '',
    String s => s,
    num n => n == n.roundToDouble() ? '${n.toInt()}' : '$n',
    _ => '$value',
  };
  void set(Object? v) => controller.setParam(node, spec.key, v);
  void setMany(JsonMap params) => controller.setParams(node, params);
}

/// Whether [spec] matters with [node]'s other settings (e.g. no credential for phone voices).
bool paramVisible(WorkflowNode node, ParamSpec spec) {
  String p(String key, String fallback) => asString(node.params[key], fallback);
  return switch ('${node.type}.${spec.key}') {
    'android.speak.credential' => p('provider', 'phone') != 'phone',
    'android.speak.style' => p('provider', 'phone') == 'openai',
    // Claude Code uses the account signed in in Ubuntu, not a stored key.
    'ai.chat.credential' => p('provider', 'anthropic') != 'claudeCode',
    // Claude Code brings its own tools; FlowDroid's tool rows are for the Claude API.
    'ai.agent.credential' || 'ai.agent.tools' => p('provider', 'anthropic') != 'claudeCode',
    'ai.agent.access' ||
    'ai.agent.folder' ||
    'ai.agent.mcpServers' ||
    'ai.agent.session' => p('provider', 'anthropic') == 'claudeCode',
    'mcp.client.url' || 'mcp.client.credential' => p('transport', 'http') == 'http',
    'mcp.client.server' => p('transport', 'http') == 'saved',
    'mcp.client.command' => p('transport', 'http') == 'stdio',
    'mcp.client.name' || 'mcp.client.arguments' => const {'callTool', 'getPrompt'}.contains(p('operation', 'callTool')),
    'mcp.client.uri' => p('operation', 'callTool') == 'readResource',
    'android.calendar.from' || 'android.calendar.to' => p('operation', 'list') != 'create',
    'android.calendar.minutes' ||
    'android.calendar.dayStart' ||
    'android.calendar.dayEnd' => p('operation', 'list') == 'freeSlots',
    'android.calendar.title' ||
    'android.calendar.start' ||
    'android.calendar.end' ||
    'android.calendar.allDay' ||
    'android.calendar.location' ||
    'android.calendar.description' => p('operation', 'list') == 'create',
    'android.contacts.query' || 'android.contacts.limit' => p('operation', 'find') == 'find',
    'android.contacts.name' || 'android.contacts.phone' || 'android.contacts.email' => p('operation', 'find') == 'add',
    'android.clock.time' || 'android.clock.days' => p('operation', 'alarm') == 'alarm',
    'android.clock.seconds' => p('operation', 'alarm') == 'timer',
    'android.clock.label' => p('operation', 'alarm') != 'showAlarms',
    'android.photo.multiple' => p('source', 'camera') == 'gallery',
    'android.photo.pages' || 'android.photo.pdf' => p('source', 'camera') == 'scan',
    // The calendar picker under "mode" writes the cron; its text is in the picker's Advanced part.
    'trigger.schedule.cron' => false,
    'trigger.schedule.minutes' => p('mode', 'interval') != 'cron',
    'rag.add.credential' || 'rag.add.model' => p('embedder', 'local') != 'local',
    // Search uses the credential the knowledge base was built with.
    'rag.search.credential' => false,
    'rag.info.collection' => p('operation', 'sources') != 'collections',
    'rag.info.source' => p('operation', 'sources') == 'deleteSource',
    _ => true,
  };
}

/// The assist for [spec] of [node], or null when it needs none.
Widget? paramAssist(EditorController controller, WorkflowNode node, ParamSpec spec) {
  final a = AssistContext(controller: controller, node: node, spec: spec);
  final key = '${node.type}.${spec.key}';
  Widget chips(List<(String label, Object value)> options) => _ValueChips(assist: a, options: options);
  return switch (key) {
    'trigger.notification.contains' => const _Note(
      'Android hides the text of sensitive notifications (one-time codes, some messages) from other apps, '
      'so a text filter can’t match those; they arrive with hidden: true. For SMS codes, use the SMS Trigger.',
    ),
    'trigger.notification.app' => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [const _AccessNote(sms: false), _AppAssist(a)],
    ),
    'trigger.sms.from' || 'android.sms.to' => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [const _AccessNote(sms: true), _ContactAssist(a, email: false)],
    ),
    'email.send.to' || 'google.gmail.to' => _ContactAssist(a, email: true),
    'trigger.place.latitude' => _PlaceAssist(a),
    'trigger.place.radius' => chips([('100 m', 100), ('200 m', 200), ('500 m', 500), ('1 km', 1000), ('5 km', 5000)]),
    'trigger.schedule.mode' => asString(node.params['mode'], 'interval') == 'cron' ? _ScheduleAssist(a) : null,
    'trigger.schedule.minutes' =>
      asString(node.params['mode'], 'interval') == 'cron'
          ? null
          : chips([('5 min', 5), ('15 min', 15), ('30 min', 30), ('1 hour', 60), ('6 hours', 360), ('1 day', 1440)]),
    'trigger.rss.minutes' || 'trigger.email.minutes' => chips([('5 min', 5), ('15 min', 15), ('1 hour', 60)]),
    'google.calendar.start' || 'google.calendar.end' => _DateTimeAssist(a),
    'google.calendar.calendarId' => chips([('Main calendar', 'primary')]),
    'ai.chat.model' => _ModelAssist(a, provider: asString(node.params['provider'], 'anthropic')),
    'ai.agent.model' => _ModelAssist(a, provider: asString(node.params['provider'], 'anthropic')),
    'google.sheets.spreadsheetId' => _IdAssist(a, IdKind.sheet, 'the sheet'),
    'google.drive.folderId' => _IdAssist(a, IdKind.driveFolder, 'the folder'),
    'google.drive.fileId' => _IdAssist(a, IdKind.driveFile, 'the file'),
    'db.notion.databaseId' => _IdAssist(a, IdKind.notionDatabase, 'the database'),
    'db.airtable.baseId' => _IdAssist(a, IdKind.airtableBase, 'the base'),
    'db.airtable.table' => _IdAssist(a, IdKind.airtableTable, 'the table'),
    'core.splitOut.field' ||
    'core.sort.field' ||
    'core.aggregate.field' ||
    'core.removeDuplicates.field' => _FieldAssist(a),
    'core.respond.contentType' => chips([('JSON', 'application/json'), ('Text', 'text/plain'), ('HTML', 'text/html')]),
    'core.respond.status' => chips([('200 OK', 200), ('201 Created', 201), ('400 Bad request', 400), ('404', 404)]),
    'google.drive.mimeType' => chips([
      ('Text', 'text/plain'),
      ('CSV', 'text/csv'),
      ('JSON', 'application/json'),
      ('PDF', 'application/pdf'),
    ]),
    'core.wait.seconds' => chips([('5 s', 5), ('30 s', 30), ('1 min', 60), ('5 min', 300), ('1 hour', 3600)]),
    'android.vibrate.ms' => chips([('Short', 200), ('Medium', 500), ('Long', 1200)]),
    'trigger.email.mailbox' => chips([('Inbox', 'INBOX')]),
    'trigger.telegram.chatId' || 'telegram.send.chatId' => _TelegramChatAssist(a),
    'mcp.client.name' || 'mcp.client.uri' => _McpFindAssist(a),
    'browser.run.steps' => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chips([
          ('Read the heading', 'extract heading h1'),
          ('Search', 'type input[name=q] {{ \$json.text }}\npress Enter\nwait for #search\nextract all results h3'),
          (
            'Log in',
            'click text="Sign in"\ntype #email you@example.com\ntype #password {{ \$json.password }}\npress Enter',
          ),
          ('Screenshot', 'screenshot page'),
        ]),
        const _Note(
          'One step per line. Targets: a CSS selector (#id, .class), text="Button label", or a number from the AI page view.\n'
          'click <target> · type <target> <text> · press Enter · wait 2 · wait for <target> · '
          'extract [all] <name> <selector> [@href] · scroll [target] · back · open <url> · screenshot [name] · js <code>\n'
          'Results are under browser.data; waits end as soon as the page is ready, nothing sleeps longer than it must.',
        ),
      ],
    ),
    'browser.run.visible' => const _Note(
      'Shows the page while it runs so you can watch or step in (a captcha, a code). Needs FlowDroid on screen; '
      'otherwise it runs hidden, which is also faster.',
    ),
    'browser.run.url' => const _Note(
      'Log in to sites first in Settings → Browser logins; the steps then run logged in.',
    ),
    'android.ask.buttons' => chips([
      ('Yes / No', 'Yes, No'),
      ('Done / Snooze', 'Done, Snooze'),
      ('Approve / Reject', 'Approve, Reject'),
    ]),
    'android.ask.timeout' => chips([('5 min', 5), ('1 hour', 60), ('1 day', 1440)]),
    'android.ask.question' => const _Note(
      'The step waits for your tap. Branch on {{ \$json.answer.button }}; it is empty if you swipe the question away, '
      'and timedOut is true if nobody answers in time.',
    ),
    'android.listen.language' => chips([
      ('Phone’s language', ''),
      ('English (US)', 'en-US'),
      ('English (UK)', 'en-GB'),
      ('Filipino', 'fil-PH'),
      ('Spanish', 'es-ES'),
    ]),
    'android.listen.prompt' => const _Note(
      'With FlowDroid open, Android’s speech box appears. In the background it listens without one, '
      'which needs microphone access; newer Android versions may block that while the app is closed.',
    ),
    'android.sound.mode' => const _Note(
      'Silent and Do Not Disturb need “Do Not Disturb access” (Settings → Phone access). '
      'The step adds the mode from before under sound, so a later step can set it back.',
    ),
    'android.calendar.calendar' => const _Note(
      'Reads every calendar the phone syncs (Google, Outlook, Samsung…). Android asks for calendar access the first time.',
    ),
    'android.calendar.dayStart' || 'android.calendar.dayEnd' || 'android.clock.time' => chips([
      ('07:00', '07:00'),
      ('08:00', '08:00'),
      ('09:00', '09:00'),
      ('17:00', '17:00'),
      ('18:00', '18:00'),
    ]),
    'android.clock.days' => chips([
      ('Once', ''),
      ('Weekdays', 'mon, tue, wed, thu, fri'),
      ('Weekends', 'sat, sun'),
      ('Every day', 'mon, tue, wed, thu, fri, sat, sun'),
    ]),
    'android.clock.seconds' => chips([('1 min', 60), ('5 min', 300), ('10 min', 600), ('25 min', 1500)]),
    'android.contacts.query' => const _Note(
      'Tip: after an SMS Trigger, search for {{ \$json.from }} to get the sender’s name.',
    ),
    'android.photo.source' => const _Note(
      'Opens the camera, the photo picker or Google’s document scanner, so FlowDroid must be on screen: '
      'run it from the app, a home-screen shortcut or the share sheet. Use the photo later as {{ \$json.file.path }}.',
    ),
    'trigger.calendar.minutes' => chips([
      ('At the time', 0),
      ('5 min', 5),
      ('10 min', 10),
      ('15 min', 15),
      ('30 min', 30),
    ]),
    'trigger.calendar.event' => const _Note(
      'Checked every minute while FlowDroid runs; all-day events are skipped. The item has the event’s title, start, end, '
      'location and calendar.',
    ),
    'trigger.mcp.name' => const _Note(
      'Settings → Webhook server shows the MCP address and how to add it to Claude Code.',
    ),
    'android.speak.text' => _SpeakTestAssist(a),
    'rag.add.collection' || 'rag.search.collection' || 'rag.info.collection' => _CollectionAssist(a),
    'rag.add.embedder' => _Note(
      asString(node.params['embedder'], 'local') == 'local'
          ? 'Words: finds chunks that share words with the question. Works offline, no key. '
                'Embeddings find answers worded differently, but need an API key or your own server.'
          : 'Embeddings: finds chunks with the same meaning, even in other words. '
                'Search uses the same provider automatically.',
    ),
    'rag.add.model' => _EmbeddingModelAssist(a),
    'rag.search.query' => const _Note('Use the result in an AI step: {{ \$json.knowledge.context }}'),
    'rag.add.chunkSize' => chips([('Short 400', 400), ('Medium 800', 800), ('Long 1500', 1500)]),
    'android.speak.voice' => _VoiceAssist(a),
    'android.speak.speed' => chips([('Slower', 0.75), ('Normal', 1), ('Faster', 1.25), ('Fast', 1.5)]),
    'android.speak.style' => chips([
      ('Calm', 'calm and warm'),
      ('Cheerful', 'cheerful and upbeat'),
      ('News', 'like a clear news reader'),
      ('Whisper', 'soft, quiet and close'),
    ]),
    'files.path' => _FilesAssist(a),
    'http.request.sendFile' ||
    'telegram.send.file' ||
    'discord.send.file' ||
    'email.send.attachments' ||
    'google.drive.file' ||
    'ai.chat.image' ||
    'files.extract.path' => _FilesAssist(a, fromInput: true),
    _ => null,
  };
}

// ---------------------------------------------------------------- shared bits

/// A row of small pills under a field.
class _Pills extends StatelessWidget {
  const _Pills({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.sm),
    child: Wrap(spacing: 6, runSpacing: 6, children: children),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap, this.icon, this.selected = false, this.leading});

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Material(
      color: selected ? c.accentSoft : c.grouped,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        canRequestFocus: false,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              if (icon != null) ...[
                Icon(icon, size: 15, color: selected ? c.accent : c.textSecondary),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected ? c.accent : c.text,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xs + 2, left: 2),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color ?? AppColors.of(context).textSecondary),
    ),
  );
}

void _toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _ValueChips extends StatelessWidget {
  const _ValueChips({required this.assist, required this.options});

  final AssistContext assist;
  final List<(String, Object)> options;

  @override
  Widget build(BuildContext context) => _Pills(
    children: [
      for (final (label, value) in options)
        _Pill(label: label, selected: assist.text == '$value', onTap: () => assist.set(value)),
    ],
  );
}

// ---------------------------------------------------------------- apps

class _AppAssist extends StatefulWidget {
  const _AppAssist(this.assist);

  final AssistContext assist;

  @override
  State<_AppAssist> createState() => _AppAssistState();
}

class _AppAssistState extends State<_AppAssist> {
  List<PhoneApp>? _apps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _apps ??= const [];
    ServicesScope.of(context).phone.installedApps().then((apps) {
      if (mounted) setState(() => _apps = apps);
    });
  }

  Future<void> _pick() async {
    final app = await AppPickerSheet.show(context);
    if (app != null) widget.assist.set(app.package);
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.assist.text.trim();
    final match = _apps?.where((a) => a.package == value).firstOrNull;
    final recent = (_apps ?? const <PhoneApp>[]).where((a) => a.recent && a.package != value).take(4);
    return _Pills(
      children: [
        if (match != null)
          _Pill(label: match.label, selected: true, leading: _AppIcon(match.icon, size: 18), onTap: _pick)
        else
          _Pill(label: value.isEmpty ? 'Choose an app' : 'Choose another app', icon: AppIcons.search, onTap: _pick),
        for (final app in recent)
          _Pill(label: app.label, leading: _AppIcon(app.icon, size: 18), onTap: () => widget.assist.set(app.package)),
      ],
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon(this.png, {this.size = 36});

  final Uint8List png;
  final double size;

  @override
  Widget build(BuildContext context) => png.isEmpty
      ? Icon(AppIcons.phone, size: size * 0.8, color: AppColors.of(context).textTertiary)
      : Image.memory(png, width: size, height: size, gaplessPlayback: true, filterQuality: FilterQuality.medium);
}

/// Searchable list of the phone's apps; pops the chosen [PhoneApp].
class AppPickerSheet extends StatefulWidget {
  const AppPickerSheet({super.key});

  static Future<PhoneApp?> show(BuildContext context) => showModalBottomSheet<PhoneApp>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const AppPickerSheet(),
  );

  @override
  State<AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<AppPickerSheet> {
  List<PhoneApp>? _apps;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_apps != null) return;
    ServicesScope.of(context).phone.installedApps().then((apps) {
      if (mounted) setState(() => _apps = apps);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _query.toLowerCase();
    final apps = (_apps ?? const <PhoneApp>[])
        .where((a) => q.isEmpty || a.label.toLowerCase().contains(q) || a.package.contains(q))
        .toList();
    final recent = q.isEmpty ? apps.where((a) => a.recent).toList() : const <PhoneApp>[];
    final rest = q.isEmpty ? apps.where((a) => !a.recent).toList() : apps;
    Widget tile(PhoneApp app) => ListTile(
      leading: _AppIcon(app.icon),
      title: Text(app.label, style: theme.textTheme.titleSmall),
      subtitle: Text(app.package, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.pop(context, app),
    );
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(AppIcons.search), hintText: 'Search apps'),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: _apps == null
                ? const Center(child: QuietSpinner())
                : ListView(
                    controller: scroll,
                    children: [
                      if (recent.isNotEmpty) ...[
                        const SectionLabel('SENT NOTIFICATIONS RECENTLY'),
                        for (final app in recent) tile(app),
                        const SectionLabel('ALL APPS'),
                      ],
                      for (final app in rest) tile(app),
                      if (apps.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(Space.xxl),
                          child: Center(child: Text('No matching apps')),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- contacts

class _ContactAssist extends StatelessWidget {
  const _ContactAssist(this.assist, {required this.email});

  final AssistContext assist;
  final bool email;

  Future<void> _pick(BuildContext context) async {
    final picked = await ServicesScope.of(context).phone.pickContact(email: email);
    if (picked == null) return;
    final current = assist.text.trim();
    // Email fields take several addresses; add to them instead of replacing.
    final next = email && current.isNotEmpty && !current.contains(picked.value)
        ? '$current, ${picked.value}'
        : (email ? (current.isEmpty ? picked.value : current) : picked.value.replaceAll(RegExp(r'[\s()-]'), ''));
    assist.set(next);
    if (context.mounted && picked.name.isNotEmpty) _toast(context, 'Added ${picked.name}');
  }

  @override
  Widget build(BuildContext context) => _Pills(
    children: [
      _Pill(label: email ? 'Add from contacts' : 'Choose a contact', icon: AppIcons.chat, onTap: () => _pick(context)),
    ],
  );
}

// ---------------------------------------------------------------- place

class _PlaceAssist extends StatefulWidget {
  const _PlaceAssist(this.assist);

  final AssistContext assist;

  @override
  State<_PlaceAssist> createState() => _PlaceAssistState();
}

class _PlaceAssistState extends State<_PlaceAssist> {
  bool _busy = false;

  Future<void> _here() async {
    setState(() => _busy = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Location is turned off on this phone';
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw 'FlowDroid may not read your location';
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      double round(double v) => (v * 1e6).roundToDouble() / 1e6;
      widget.assist.setMany({'latitude': round(p.latitude), 'longitude': round(p.longitude)});
      if (mounted) _toast(context, 'Set to where you are (± ${p.accuracy.round()} m)');
    } on Object catch (e) {
      if (mounted) _toast(context, e is String ? e : 'Could not get your location');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lat = asDouble(widget.assist.node.params['latitude']);
    final lng = asDouble(widget.assist.node.params['longitude']);
    return _Pills(
      children: [
        _Pill(
          label: _busy ? 'Finding you…' : 'Use where I am now',
          icon: AppIcons.locate,
          onTap: _busy ? () {} : _here,
        ),
        if (lat != 0 || lng != 0)
          _Pill(
            label: 'Show on map',
            icon: AppIcons.place,
            onTap: () => launchUrl(Uri.parse('geo:$lat,$lng?q=$lat,$lng'), mode: LaunchMode.externalApplication),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- date and time

class _DateTimeAssist extends StatelessWidget {
  const _DateTimeAssist(this.assist);

  final AssistContext assist;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(assist.text)?.toLocal() ?? now.add(const Duration(hours: 1));
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null) return;
    assist.set(isoWithOffset(DateTime(date.year, date.month, date.day, time.hour, time.minute)));
  }

  @override
  Widget build(BuildContext context) {
    final isEnd = assist.spec.key == 'end';
    final start = DateTime.tryParse(asString(assist.node.params['start']));
    return _Pills(
      children: [
        _Pill(label: 'Pick date and time', icon: AppIcons.calendar, onTap: () => _pick(context)),
        if (isEnd && start != null) ...[
          _Pill(
            label: '30 min after start',
            onTap: () => assist.set(isoWithOffset(start.toLocal().add(const Duration(minutes: 30)))),
          ),
          _Pill(
            label: '1 hour after start',
            onTap: () => assist.set(isoWithOffset(start.toLocal().add(const Duration(hours: 1)))),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- AI models

class _ModelAssist extends StatelessWidget {
  const _ModelAssist(this.assist, {required this.provider});

  final AssistContext assist;
  final String provider;

  @override
  Widget build(BuildContext context) {
    final models = modelSuggestions[provider] ?? const <String>[];
    if (models.isEmpty) return const SizedBox.shrink();
    final value = assist.text.trim();
    // No fixed default: the server's models, or Claude Code's own choice.
    final hasDefault = provider != 'openaiCompatible' && provider != 'claudeCode';
    return _Pills(
      children: [
        for (final (i, m) in models.indexed)
          _Pill(
            label: i == 0 && hasDefault ? '$m (default)' : m,
            selected: value == m || (i == 0 && value.isEmpty && hasDefault),
            onTap: () => assist.set(i == 0 && hasDefault ? '' : m),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------- IDs inside links

class _IdAssist extends StatefulWidget {
  const _IdAssist(this.assist, this.kind, this.what);

  final AssistContext assist;
  final IdKind kind;
  final String what;

  @override
  State<_IdAssist> createState() => _IdAssistState();
}

class _IdAssistState extends State<_IdAssist> {
  String? _took;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(_IdAssist old) {
    super.didUpdateWidget(old);
    _check();
  }

  /// A pasted link becomes just its ID.
  void _check() {
    final id = idFromLink(widget.kind, widget.assist.text);
    if (id == null) return;
    _took = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.assist.set(id);
    });
  }

  @override
  Widget build(BuildContext context) => _Note(
    _took != null && widget.assist.text == _took
        ? 'Took the ID from the link.'
        : 'Paste the link to ${widget.what}; FlowDroid keeps just the ID.',
  );
}

// ---------------------------------------------------------------- field names from the input

class _FieldAssist extends StatelessWidget {
  const _FieldAssist(this.assist);

  final AssistContext assist;

  @override
  Widget build(BuildContext context) {
    final sources = MappingScope.of(context)?.sources ?? const <DataSource>[];
    final input = sources.where((s) => s.title == 'Input').firstOrNull;
    final first = (input?.value as List?)?.firstOrNull;
    if (first is! Map) {
      return const _Note('Run the workflow once to choose from the fields that arrive here.');
    }
    final paths = fieldPaths(asMap(first)).take(24).toList();
    return _Pills(
      children: [for (final p in paths) _Pill(label: p, selected: assist.text == p, onTap: () => assist.set(p))],
    );
  }
}

// ---------------------------------------------------------------- Telegram chats

class _TelegramChatAssist extends StatefulWidget {
  const _TelegramChatAssist(this.assist);

  final AssistContext assist;

  @override
  State<_TelegramChatAssist> createState() => _TelegramChatAssistState();
}

class _TelegramChatAssistState extends State<_TelegramChatAssist> {
  List<(String id, String title)>? _chats;
  bool _busy = false;
  String? _error;

  Future<void> _find() async {
    final name = asString(widget.assist.node.params['credential']);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = (await ServicesScope.of(context).credentials.byName(name))?.values['botToken'] ?? '';
      if (token.isEmpty) throw 'Choose the bot’s credential first';
      final r = await http.get(Uri.parse('https://api.telegram.org/bot$token/getUpdates?limit=100'));
      final body = asMap(jsonDecode(r.body));
      if (body['ok'] != true) throw asString(body['description'], 'Telegram said no');
      final chats = <String, String>{};
      for (final u in asMapList(body['result'])) {
        final msg = asMap(u['message'] ?? u['channel_post'] ?? u['edited_message'] ?? asMap(u['my_chat_member']));
        final chat = asMap(msg['chat']);
        if (chat['id'] == null) continue;
        final title = asString(
          chat['title'],
          [asString(chat['first_name']), asString(chat['last_name'])].join(' ').trim(),
        );
        chats['${chat['id']}'] = title.isEmpty ? asString(chat['username'], '${chat['id']}') : title;
      }
      setState(() => _chats = [for (final e in chats.entries) (e.key, e.value)]);
      if (chats.isEmpty) _error = 'No chats yet. Send your bot a message in Telegram, then tap again.';
    } on SocketException {
      _error = 'No internet connection';
    } on Object catch (e) {
      _error = e is String ? e : 'Could not reach Telegram';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Pills(
        children: [
          _Pill(label: _busy ? 'Looking…' : 'Find my chats', icon: AppIcons.send, onTap: _busy ? () {} : _find),
          for (final (id, title) in _chats ?? const <(String, String)>[])
            _Pill(label: title, selected: widget.assist.text == id, onTap: () => widget.assist.set(id)),
        ],
      ),
      if (_error != null) _Note(_error!, color: AppColors.of(context).warning),
    ],
  );
}

// ---------------------------------------------------------------- MCP tools, prompts, resources

/// Asks the MCP server what it offers and fills in the name (and an
/// arguments skeleton from the tool's schema) on a tap.
class _McpFindAssist extends StatefulWidget {
  const _McpFindAssist(this.assist);

  final AssistContext assist;

  @override
  State<_McpFindAssist> createState() => _McpFindAssistState();
}

class _McpFindAssistState extends State<_McpFindAssist> {
  List<JsonMap>? _found;
  bool _busy = false;
  String? _error;

  JsonMap get _params => widget.assist.node.params;
  String get _operation => asString(_params['operation'], 'callTool');

  /// What to list for the field: resources for the URI, prompts or tools for the name.
  (String method, String what) get _list => switch ((widget.assist.spec.key, _operation)) {
    ('uri', _) => ('resources/list', 'resources'),
    (_, 'getPrompt') => ('prompts/list', 'prompts'),
    _ => ('tools/list', 'tools'),
  };

  /// The server as the node describes it; expressions can't be followed here.
  JsonMap _server() {
    String text(String key) {
      final v = asString(_params[key]).trim();
      if (v.contains('{{')) throw 'Uses an expression; type the server itself to look it up';
      return v;
    }

    return switch (asString(_params['transport'], 'http')) {
      'stdio' => {'transport': 'stdio', 'command': text('command')},
      'saved' => {'transport': 'saved', 'credential': text('server')},
      _ => {
        'transport': 'http',
        'url': text('url'),
        if (text('credential').isNotEmpty) 'credential': text('credential'),
      },
    };
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final mcp = ServicesScope.of(context).mcp;
    try {
      final server = _server();
      if ([server['url'], server['command'], server['credential']].every((v) => asString(v).isEmpty)) {
        throw 'Fill in the server first';
      }
      final found = await mcp.listAll(server, _list.$1, const Duration(minutes: 2));
      setState(() => _found = found);
      if (found.isEmpty) _error = 'The server offers no ${_list.$2}.';
    } on McpException catch (e) {
      _error = e.message;
    } on Object catch (e) {
      _error = e is String ? e : 'Could not reach the server';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pick(JsonMap entry) {
    if (widget.assist.spec.key == 'uri') return widget.assist.set(asString(entry['uri']));
    final name = asString(entry['name']);
    final current = asString(_params['arguments']).trim();
    // Only fill the arguments when there are none yet, so typed values are kept.
    final empty = current.isEmpty || current == '{}';
    widget.assist.setMany({
      'name': name,
      if (empty) 'arguments': const JsonEncoder.withIndent('  ').convert(_skeleton(entry)),
    });
  }

  /// `{"query": "", "limit": 0}` from a tool's input schema, or a prompt's argument list.
  static JsonMap _skeleton(JsonMap entry) {
    final prompt = asMapList(entry['arguments']);
    if (prompt.isNotEmpty) return {for (final a in prompt) asString(a['name']): ''};
    return {
      for (final MapEntry(:key, :value) in asMap(asMap(entry['inputSchema'])['properties']).entries)
        key: switch (asMap(value)['type']) {
          'number' || 'integer' => 0,
          'boolean' => false,
          'array' => <Object?>[],
          'object' => <String, Object?>{},
          _ => '',
        },
    };
  }

  String _label(JsonMap entry) => widget.assist.spec.key == 'uri'
      ? asString(entry['name'], asString(entry['uri']))
      : asString(entry['title'], asString(entry['name']));

  bool _selected(JsonMap entry) =>
      widget.assist.text == (widget.assist.spec.key == 'uri' ? asString(entry['uri']) : asString(entry['name']));

  @override
  Widget build(BuildContext context) {
    final picked = (_found ?? const <JsonMap>[]).where(_selected).firstOrNull;
    final description = asString(picked?['description']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Pills(
          children: [
            _Pill(label: _busy ? 'Looking…' : 'Find ${_list.$2}', icon: AppIcons.search, onTap: _busy ? () {} : _find),
            for (final entry in _found ?? const <JsonMap>[])
              _Pill(label: _label(entry), selected: _selected(entry), onTap: () => _pick(entry)),
          ],
        ),
        if (description.isNotEmpty) _Note(description),
        if (_error != null) _Note(_error!, color: AppColors.of(context).warning),
      ],
    );
  }
}

// ---------------------------------------------------------------- files

class _FilesAssist extends StatelessWidget {
  const _FilesAssist(this.assist, {this.fromInput = false});

  final AssistContext assist;

  /// Also offer "the file from the previous step".
  final bool fromInput;

  @override
  Widget build(BuildContext context) {
    final dir = Directory('${ServicesScope.of(context).dataDir.path}/files');
    final entries = dir.existsSync()
        ? (dir.listSync(recursive: true).whereType<File>().toList()
            ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified)))
        : const <File>[];
    const previous = r'{{ $json.file.path }}';
    if (entries.isEmpty && !fromInput) return const _Note('No files in FlowDroid’s folder yet.');
    return _Pills(
      children: [
        if (fromInput)
          _Pill(
            label: 'File from the previous step',
            icon: AppIcons.result,
            selected: assist.text == previous,
            onTap: () => assist.set(previous),
          ),
        for (final f in entries.take(12))
          () {
            final rel = f.path.substring(dir.path.length + 1);
            return _Pill(label: rel, icon: AppIcons.folder, selected: assist.text == rel, onTap: () => assist.set(rel));
          }(),
      ],
    );
  }
}

// ---------------------------------------------------------------- permissions the step needs

/// Says so, with a button, when the step can't work until the user allows something.
class _AccessNote extends StatefulWidget {
  const _AccessNote({required this.sms});

  final bool sms;

  @override
  State<_AccessNote> createState() => _AccessNoteState();
}

class _AccessNoteState extends State<_AccessNote> with WidgetsBindingObserver {
  bool? _ok;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final access = await ServicesScope.of(context).phone.access();
      if (mounted) setState(() => _ok = widget.sms ? access.sms : access.notificationAccess);
    } on Object {
      // Not on Android.
    }
  }

  Future<void> _allow() async {
    final phone = ServicesScope.of(context).phone;
    await (widget.sms ? phone.requestSms() : phone.openNotificationAccess());
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_ok != false) return const SizedBox.shrink();
    final c = AppColors.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Space.sm),
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.xs, Space.sm),
      decoration: BoxDecoration(color: c.warningSoft, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          Icon(AppIcons.warning, size: 16, color: c.warning),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              widget.sms
                  ? 'FlowDroid may not read or send SMS yet, so this step can’t run.'
                  : 'FlowDroid can’t see notifications yet, so this trigger won’t fire.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.text),
            ),
          ),
          TextButton(onPressed: _allow, child: const Text('Allow')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- voices

/// The Speak Text effect for the node's current settings, with [text] already rendered.
JsonMap _speakEffect(WorkflowNode node, String text) {
  final p = node.params;
  final provider = asString(p['provider'], 'phone');
  return {
    'type': 'speak',
    'text': text,
    if (provider != 'phone') ...{'provider': provider, 'credential': asString(p['credential'])},
    if (asString(p['voice']).isNotEmpty) 'voice': p['voice'],
    'speed': asDouble(p['speed'], 1),
    if (asString(p['style']).isNotEmpty) 'style': p['style'],
  };
}

/// "Test": speaks the text now with the chosen voice (expressions filled from the last run).
class _SpeakTestAssist extends StatefulWidget {
  const _SpeakTestAssist(this.assist);

  final AssistContext assist;

  @override
  State<_SpeakTestAssist> createState() => _SpeakTestAssistState();
}

class _SpeakTestAssistState extends State<_SpeakTestAssist> {
  bool _playing = false;

  Future<void> _test() async {
    final a = widget.assist;
    final speech = ServicesScope.of(context).speech;
    if (_playing) {
      await speech.stop();
      return;
    }
    var text = a.text;
    try {
      final v = a.controller.services.core.evaluateTemplate(text, a.controller.previewContext(a.node));
      text = v is String ? v : jsonEncode(v);
    } on Object {
      // Speak it as written.
    }
    if (text.trim().isEmpty) text = 'Hi! This is how I sound.';
    setState(() => _playing = true);
    final result = await speech.call(_speakEffect(a.node, text));
    if (!mounted) return;
    setState(() => _playing = false);
    if (result['error'] case final String error) _toast(context, error);
  }

  @override
  Widget build(BuildContext context) => _Pills(
    children: [
      _Pill(
        label: _playing ? 'Stop' : 'Test the voice',
        icon: _playing ? AppIcons.pauseCircle : AppIcons.speak,
        onTap: _test,
      ),
    ],
  );
}

class _VoiceAssist extends StatelessWidget {
  const _VoiceAssist(this.assist);

  final AssistContext assist;

  @override
  Widget build(BuildContext context) {
    final provider = asString(assist.node.params['provider'], 'phone');
    final value = assist.text;
    final known = provider == 'openai' ? openAiVoices.where((v) => v.id == value).firstOrNull : null;
    return _Pills(
      children: [
        _Pill(
          label: value.isEmpty ? 'Choose a voice' : 'Voice: ${known?.name ?? value}',
          icon: AppIcons.speak,
          selected: value.isNotEmpty,
          onTap: () async {
            final chosen = await VoicePickerSheet.show(
              context,
              provider: provider,
              credential: asString(assist.node.params['credential']),
              current: value,
            );
            if (chosen != null) assist.set(chosen.id);
          },
        ),
        if (value.isNotEmpty) _Pill(label: 'Default voice', onTap: () => assist.set('')),
      ],
    );
  }
}

/// Lists voices for one provider, with a sample button on each; pops the chosen one.
class VoicePickerSheet extends StatefulWidget {
  const VoicePickerSheet({super.key, required this.provider, required this.credential, required this.current});

  final String provider;
  final String credential;
  final String current;

  static Future<VoiceOption?> show(
    BuildContext context, {
    required String provider,
    required String credential,
    required String current,
  }) => showModalBottomSheet<VoiceOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => VoicePickerSheet(provider: provider, credential: credential, current: current),
  );

  @override
  State<VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends State<VoicePickerSheet> {
  List<VoiceOption>? _voices;
  String? _error;
  String _query = '';
  bool _naturalOnly = true;
  String? _playing;

  late Speech _speech;
  late PhoneBridge _phone;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _speech = ServicesScope.of(context).speech;
    _phone = ServicesScope.of(context).phone;
    if (_voices == null && _error == null) _load();
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final voices = switch (widget.provider) {
        'openai' => openAiVoices,
        'elevenlabs' => await _speech.elevenLabsVoices(widget.credential),
        _ => await _speech.phoneVoices(),
      };
      if (!mounted) return;
      setState(() {
        _voices = voices;
        // Show everything when the phone has no natural voices to filter to.
        if (!voices.any((v) => v.natural)) _naturalOnly = false;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = e is SpeechException ? e.message : 'Could not load the voices');
    }
  }

  Future<void> _sample(VoiceOption v) async {
    if (_playing == v.id) {
      await _speech.stop();
      return;
    }
    await _speech.stop();
    setState(() => _playing = v.id);
    String? error;
    if (widget.provider == 'phone') {
      await _speech.previewPhone(v);
    } else if (v.previewUrl != null) {
      error = await _phone.playAudio(v.previewUrl!);
    } else {
      final r = await _speech.call({
        'type': 'speak',
        'text': 'Hi! This is how I sound.',
        'provider': widget.provider,
        'credential': widget.credential,
        'voice': v.id,
      });
      error = r['error'] as String?;
    }
    if (!mounted) return;
    setState(() => _playing = null);
    if (error != null) _toast(context, error);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final q = _query.toLowerCase();
    final all = _voices ?? const <VoiceOption>[];
    final shown = all
        .where((v) => !_naturalOnly || v.natural)
        .where((v) => q.isEmpty || '${v.name} ${v.detail} ${v.locale}'.toLowerCase().contains(q))
        .toList();
    // The phone's own language first.
    final here = Localizations.localeOf(context).languageCode;
    shown.sort((a, b) {
      final ah = a.locale.startsWith(here), bh = b.locale.startsWith(here);
      return ah == bh ? 0 : (ah ? -1 : 1);
    });
    final note = switch (widget.provider) {
      'openai' => 'OpenAI voices · samples use your OpenAI key (a fraction of a cent each)',
      'elevenlabs' => 'Voices in your ElevenLabs account · samples are free',
      _ => 'Voices installed on this phone · they work offline unless marked online',
    };
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
            child: Text('Choose a voice', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.md),
            child: Text(note, style: theme.textTheme.bodySmall),
          ),
          if (widget.provider != 'openai')
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(AppIcons.search),
                  hintText: 'Search voices or languages',
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),
          if (widget.provider == 'phone' && all.any((v) => v.natural))
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
              child: Row(
                children: [
                  _Pill(
                    label: 'Natural voices',
                    selected: _naturalOnly,
                    onTap: () => setState(() => _naturalOnly = true),
                  ),
                  const SizedBox(width: 6),
                  _Pill(
                    label: 'All voices',
                    selected: !_naturalOnly,
                    onTap: () => setState(() => _naturalOnly = false),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.all(Space.page),
                    child: Text(_error!, style: TextStyle(color: c.danger)),
                  )
                : _voices == null
                ? const Center(child: QuietSpinner())
                : ListView(
                    controller: scroll,
                    children: [
                      for (final v in shown)
                        ListTile(
                          selected: v.id == widget.current,
                          selectedTileColor: c.accentSoft,
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(v.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                              ),
                              if (v.natural && widget.provider == 'phone') ...[
                                const SizedBox(width: Space.sm),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: c.successSoft,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text('Natural', style: theme.textTheme.labelSmall?.copyWith(color: c.success)),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(v.detail, maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            tooltip: 'Play a sample',
                            icon: Icon(_playing == v.id ? AppIcons.pauseCircle : AppIcons.playCircle),
                            onPressed: () => _sample(v),
                          ),
                          onTap: () => Navigator.pop(context, v),
                        ),
                      if (shown.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(Space.xxl),
                          child: Center(child: Text('No matching voices')),
                        ),
                      if (widget.provider == 'phone')
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Space.page, Space.lg, Space.page, Space.xxl),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'More natural voices: open Text-to-speech settings, choose Speech Services by Google, '
                                'then Install voice data and download your language.',
                                style: theme.textTheme.bodySmall,
                              ),
                              const SizedBox(height: Space.sm),
                              _Pill(
                                label: 'Open text-to-speech settings',
                                icon: AppIcons.external,
                                onTap: () => ServicesScope.of(context).phone.openBackgroundSettings('tts'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- calendar schedule

/// Whether the phone shows 24-hour time.
bool _h24(BuildContext context) => MediaQuery.alwaysUse24HourFormatOf(context);

String _nextRuns(BuildContext context, String cron, {int count = 3}) {
  final core = ServicesScope.of(context).core;
  final out = <String>[];
  var after = DateTime.now();
  try {
    for (var i = 0; i < count; i++) {
      final n = core.nextCronRun(cron, after, after.toLocal().timeZoneOffset);
      if (n == null) break;
      final l = n.toLocal();
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      out.add('${days[l.weekday - 1]} ${l.day}/${l.month} ${formatClock(l.hour, l.minute, h24: _h24(context))}');
      after = n;
    }
  } on Object {
    return '';
  }
  return out.join(' · ');
}

/// The schedule as a sentence with its next runs, and a button to change it.
class _ScheduleAssist extends StatelessWidget {
  const _ScheduleAssist(this.assist);

  final AssistContext assist;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final theme = Theme.of(context);
    final cron = asString(assist.node.params['cron']).trim();
    final words = cron.isEmpty ? null : describeCron(cron, h24: _h24(context));
    final next = cron.isEmpty ? '' : _nextRuns(context, cron);
    final valid = cron.isNotEmpty && next.isNotEmpty;
    Future<void> edit() async {
      final picked = await ScheduleSheet.show(context, cron);
      if (picked != null) assist.controller.setParam(assist.node, 'cron', picked);
    }

    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Material(
        color: c.grouped,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: edit,
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(11)),
                  child: Icon(AppIcons.calendar, size: 20, color: valid ? c.accent : c.textTertiary),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cron.isEmpty
                            ? 'Choose when it runs'
                            : (valid ? (words ?? 'Custom schedule') : 'This schedule is not valid'),
                        style: theme.textTheme.titleSmall?.copyWith(color: valid || cron.isEmpty ? c.text : c.warning),
                      ),
                      if (valid) ...[
                        const SizedBox(height: 2),
                        Text('Next: $next', style: theme.textTheme.bodySmall, maxLines: 2),
                      ],
                    ],
                  ),
                ),
                Icon(AppIcons.chevronRight, color: c.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Picks a schedule like a calendar app: how often, which days, what time. Pops the cron text.
class ScheduleSheet extends StatefulWidget {
  const ScheduleSheet({super.key, required this.cron});

  final String cron;

  static Future<String?> show(BuildContext context, String cron) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ScheduleSheet(cron: cron),
  );

  @override
  State<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<ScheduleSheet> {
  late ScheduleSpec _spec = ScheduleSpec.fromCron(widget.cron) ?? const ScheduleSpec();
  late final _raw = TextEditingController(text: widget.cron);
  late bool _advanced = widget.cron.trim().isNotEmpty && ScheduleSpec.fromCron(widget.cron) == null;

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  void _set(ScheduleSpec spec) => setState(() {
    _spec = spec;
    _raw.text = spec.toCron();
  });

  String get _cron => _advanced ? _raw.text.trim() : _spec.toCron();

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _spec.hour, minute: _spec.minute),
    );
    if (t != null) _set(_spec.copyWith(hour: t.hour, minute: t.minute));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final cron = _cron;
    final next = _nextRuns(context, cron);
    final words = describeCron(cron, h24: _h24(context));
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Text(text, style: theme.textTheme.labelMedium),
    );
    Widget chips<T>(List<(String, T)> options, T selected, ValueChanged<T> onTap) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final (l, v) in options) _Pill(label: l, selected: v == selected, onTap: () => onTap(v))],
    );
    final time = formatClock(_spec.hour, _spec.minute, h24: _h24(context));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
              children: [
                Text('When should it run?', style: theme.textTheme.titleLarge),
                label('REPEATS'),
                chips<Repeat>(
                  const [
                    ('Every few minutes', Repeat.minutes),
                    ('Hourly', Repeat.hourly),
                    ('Daily', Repeat.daily),
                    ('Weekly', Repeat.weekly),
                    ('Monthly', Repeat.monthly),
                  ],
                  _spec.repeat,
                  (r) => _set(
                    _spec.copyWith(repeat: r, every: r == Repeat.minutes ? 15 : (r == Repeat.hourly ? 1 : _spec.every)),
                  ),
                ),
                if (_spec.repeat == Repeat.minutes) ...[
                  label('EVERY'),
                  chips<int>(
                    const [('1 min', 1), ('5 min', 5), ('10 min', 10), ('15 min', 15), ('30 min', 30)],
                    _spec.every,
                    (v) => _set(_spec.copyWith(every: v)),
                  ),
                ],
                if (_spec.repeat == Repeat.hourly) ...[
                  label('EVERY'),
                  chips<int>(
                    const [
                      ('1 hour', 1),
                      ('2 hours', 2),
                      ('3 hours', 3),
                      ('4 hours', 4),
                      ('6 hours', 6),
                      ('12 hours', 12),
                    ],
                    _spec.every,
                    (v) => _set(_spec.copyWith(every: v)),
                  ),
                  label('AT MINUTE'),
                  chips<int>(
                    const [(':00', 0), (':15', 15), (':30', 30), (':45', 45)],
                    _spec.minute,
                    (v) => _set(_spec.copyWith(minute: v)),
                  ),
                ],
                if (_spec.repeat.index >= Repeat.daily.index) ...[
                  label('AT'),
                  Material(
                    color: c.grouped,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _pickTime,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
                        child: Row(
                          children: [
                            Text(time, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
                            const Spacer(),
                            Icon(AppIcons.clock, color: c.textSecondary),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (_spec.repeat == Repeat.weekly) ...[
                  label('ON'),
                  _WeekdayPicker(
                    selected: _spec.weekdays,
                    onChanged: (d) => _set(_spec.copyWith(weekdays: d)),
                  ),
                  const SizedBox(height: Space.sm),
                  chips<Set<int>>(
                    const [
                      ('Weekdays', {1, 2, 3, 4, 5}),
                      ('Weekends', {0, 6}),
                      ('Every day', {0, 1, 2, 3, 4, 5, 6}),
                    ],
                    _spec.weekdays,
                    (v) => _set(_spec.copyWith(weekdays: v)),
                  ),
                ],
                if (_spec.repeat == Repeat.monthly) ...[
                  label('ON THESE DAYS OF THE MONTH'),
                  _MonthDayPicker(
                    selected: _spec.monthDays,
                    onChanged: (d) => _set(_spec.copyWith(monthDays: d)),
                  ),
                  if (_spec.monthDays.any((d) => d > 28))
                    const _Note('Months without that day (like the 31st in April) skip it.'),
                ],
                const SizedBox(height: Space.xl),
                Container(
                  padding: const EdgeInsets.all(Space.lg),
                  decoration: BoxDecoration(
                    color: next.isEmpty ? c.warningSoft : c.accentSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        next.isEmpty ? 'This schedule never runs' : (words ?? 'Custom schedule'),
                        style: theme.textTheme.titleSmall?.copyWith(color: next.isEmpty ? c.warning : c.accent),
                      ),
                      if (next.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('Next runs: $next', style: theme.textTheme.bodySmall?.copyWith(color: c.text)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Space.md),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _advanced = !_advanced),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Space.sm),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: _advanced ? 0.25 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(AppIcons.chevronRight, size: 16, color: c.textSecondary),
                        ),
                        const SizedBox(width: 6),
                        Text('Advanced: write it as cron', style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ),
                ),
                if (_advanced) ...[
                  TextField(
                    controller: _raw,
                    style: AppTheme.monospace.copyWith(color: c.text),
                    decoration: const InputDecoration(hintText: 'minute hour day month weekday'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const _Note('Typing here replaces the choices above.'),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, Space.sm, Space.page, Space.md),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: next.isEmpty ? null : () => Navigator.pop(context, cron),
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Seven round day toggles, Monday first.
class _WeekdayPicker extends StatelessWidget {
  const _WeekdayPicker({required this.selected, required this.onChanged});

  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    const order = [1, 2, 3, 4, 5, 6, 0];
    const letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    const names = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final (i, d) in order.indexed)
          _DayDot(
            label: letters[i],
            semantics: names[i],
            on: selected.contains(d),
            onTap: () => onChanged(selected.contains(d) ? ({...selected}..remove(d)) : {...selected, d}),
          ),
      ],
    );
  }
}

/// Days 1–31 laid out like a month page.
class _MonthDayPicker extends StatelessWidget {
  const _MonthDayPicker({required this.selected, required this.onChanged});

  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = ((box.maxWidth - 6 * 8) / 7).clamp(32.0, 48.0);
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var d = 1; d <= 31; d++)
            SizedBox(
              width: size,
              height: size,
              child: _DayDot(
                label: '$d',
                semantics: 'Day $d',
                on: selected.contains(d),
                onTap: () {
                  final next = selected.contains(d) ? ({...selected}..remove(d)) : {...selected, d};
                  if (next.isNotEmpty) onChanged(next);
                },
              ),
            ),
        ],
      );
    },
  );
}

class _DayDot extends StatelessWidget {
  const _DayDot({required this.label, required this.semantics, required this.on, required this.onTap});

  final String label;
  final String semantics;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      label: semantics,
      selected: on,
      button: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: on ? c.accent : c.grouped),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: 14,
              color: on ? Colors.white : c.text,
              fontWeight: on ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- knowledge bases

class _CollectionAssist extends StatelessWidget {
  const _CollectionAssist(this.assist);

  final AssistContext assist;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<JsonMap>>(
    future: ServicesScope.of(context).knowledge.collections(),
    builder: (context, snap) {
      final names = [for (final c in snap.data ?? const <JsonMap>[]) asString(c['name'])];
      if (names.isEmpty) {
        return const _Note('No knowledge bases yet: the first Add creates this one.');
      }
      return _Pills(
        children: [
          for (final n in names)
            _Pill(label: n, icon: AppIcons.database, selected: assist.text == n, onTap: () => assist.set(n)),
        ],
      );
    },
  );
}

class _EmbeddingModelAssist extends StatelessWidget {
  const _EmbeddingModelAssist(this.assist);

  final AssistContext assist;

  static const _models = {
    'openai': ['text-embedding-3-small', 'text-embedding-3-large'],
    'gemini': ['text-embedding-004', 'gemini-embedding-001'],
    'openaiCompatible': ['nomic-embed-text', 'mxbai-embed-large', 'bge-m3'],
  };

  @override
  Widget build(BuildContext context) {
    final provider = asString(assist.node.params['embedder'], 'local');
    final models = _models[provider] ?? const <String>[];
    final value = assist.text;
    return _Pills(
      children: [
        for (final (i, m) in models.indexed)
          _Pill(
            label: i == 0 ? '$m (default)' : m,
            selected: value == m || (i == 0 && value.isEmpty),
            onTap: () => assist.set(i == 0 ? '' : m),
          ),
      ],
    );
  }
}
