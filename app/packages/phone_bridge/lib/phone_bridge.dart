import 'dart:async';

import 'package:flutter/services.dart';

/// Which phone features FlowDroid may use.
class PhoneAccess {
  const PhoneAccess({
    required this.sms,
    required this.notificationAccess,
    this.calendar = false,
    this.contacts = false,
    this.microphone = false,
    this.dnd = false,
  });

  final bool sms;
  final bool notificationAccess;
  final bool calendar;
  final bool contacts;
  final bool microphone;

  /// May change Do Not Disturb (and switch the ringer to silent).
  final bool dnd;
}

/// What can stop FlowDroid from running in the background on this phone.
class BackgroundStatus {
  const BackgroundStatus({
    this.maker = '',
    this.brand = '',
    this.model = '',
    this.sdk = 0,
    this.hasAutostartScreen = false,
    this.batteryUnrestricted = false,
    this.exactAlarms = true,
    this.notifications = true,
    this.backgroundRestricted = false,
    this.overlay = false,
  });

  factory BackgroundStatus.fromMap(Map<String, Object?> m) => BackgroundStatus(
    maker: m['maker'] as String? ?? '',
    brand: m['brand'] as String? ?? '',
    model: m['model'] as String? ?? '',
    sdk: m['sdk'] as int? ?? 0,
    hasAutostartScreen: m['hasAutostartScreen'] == true,
    batteryUnrestricted: m['batteryUnrestricted'] == true,
    exactAlarms: m['exactAlarms'] != false,
    notifications: m['notifications'] != false,
    backgroundRestricted: m['backgroundRestricted'] == true,
    overlay: m['overlay'] == true,
  );

  /// Lower-case maker, e.g. `huawei`, `xiaomi`, `samsung`.
  final String maker;
  final String brand;
  final String model;
  final int sdk;

  /// The maker has its own auto-launch manager that FlowDroid can open.
  final bool hasAutostartScreen;
  final bool batteryUnrestricted;
  final bool exactAlarms;
  final bool notifications;

  /// The user (or Android) turned on "Restrict background activity" for FlowDroid.
  final bool backgroundRestricted;

  /// "Display over other apps": lets workflows open links and apps from the background.
  final bool overlay;
}

/// An app on the phone.
class PhoneApp {
  const PhoneApp({required this.package, required this.label, required this.icon, this.recentRank = -1});

  final String package;
  final String label;

  /// PNG, 96 px; empty when the icon could not be drawn.
  final Uint8List icon;

  /// 0 = posted a notification most recently; -1 = not recently.
  final int recentRank;

  bool get recent => recentRank >= 0;
}

/// A phone number or email address chosen from the contacts.
typedef PickedContact = ({String name, String value});

/// What FlowDroid was opened for: content shared from another app, or a workflow shortcut.
sealed class Launch {
  const Launch();
}

class SharedContent extends Launch {
  const SharedContent({this.text, this.subject, this.files = const []});

  final String? text;
  final String? subject;

  /// Paths inside FlowDroid's folder (e.g. `shared/123-photo.jpg`).
  final List<String> files;
}

class WorkflowShortcut extends Launch {
  const WorkflowShortcut(this.workflowId);

  final String workflowId;
}

/// Android features behind FlowDroid's phone triggers and nodes.
class PhoneBridge {
  PhoneBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launch') _launches.add(null);
    });
  }

  static const _channel = MethodChannel('flowdroid/phone');
  static final _launches = StreamController<void>.broadcast();

  /// Fires when the app is opened again with something to handle; then call [takeLaunch].
  Stream<void> get launches => _launches.stream;

  Future<PhoneAccess> access() async {
    final map = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return PhoneAccess(
      sms: map['sms'] == true,
      notificationAccess: map['notificationAccess'] == true,
      calendar: map['calendar'] == true,
      contacts: map['contacts'] == true,
      microphone: map['microphone'] == true,
      dnd: map['dnd'] == true,
    );
  }

  /// Whether FlowDroid has `calendar`, `contacts` and/or `microphone` access,
  /// asking for what is missing when the app is on screen.
  Future<bool> ensurePermissions(List<String> names) async {
    try {
      return await _channel.invokeMethod<bool>('ensurePermissions', {'names': names}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens Android's "Do Not Disturb access" screen.
  Future<void> openDndAccess() => _channel.invokeMethod<void>('openDndAccess');

  /// Calls a productivity method; its answer, or `{error}` off Android.
  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      return {'error': 'this step only works on Android'};
    } on PlatformException catch (e) {
      return {'error': e.message ?? e.code};
    }
  }

  /// Events (repeating ones included) between [from] and [to]: `[{id, title,
  /// start, end (epoch ms), allDay, location, description, calendar, busy}]`, or `{error}`.
  Future<Object?> calendarEvents(DateTime from, DateTime to, String calendar) => _call('calendarEvents', {
    'from': from.millisecondsSinceEpoch,
    'to': to.millisecondsSinceEpoch,
    'calendar': calendar,
  });

  /// Adds an event (`start`/`end` in epoch ms); its id, or `{error}`.
  Future<Object?> calendarCreate(Map<String, Object?> event) => _call('calendarCreate', {'event': event});

  /// `[{id, name, phones, emails}]` matching a name or number, or `{error}`.
  Future<Object?> contactsFind(String query, int limit) => _call('contactsFind', {'query': query, 'limit': limit});

  /// Adds a contact to the phone; its id, or `{error}`.
  Future<Object?> contactsAdd(String name, String phone, String email) =>
      _call('contactsAdd', {'name': name, 'phone': phone, 'email': email});

  /// Posts an Ask Me question; the answer appears as `answers/<id>.json` in the app's documents folder.
  Future<Object?> ask(String id, String title, String question, List<String> buttons, bool reply) =>
      _call('ask', {'id': id, 'title': title, 'question': question, 'buttons': buttons, 'reply': reply});

  Future<Object?> askCancel(String id) => _call('askCancel', {'id': id});

  /// `{text, confidence, cancelled?}` or `{error}`.
  Future<Object?> listen(String language, String prompt, int maxMs) =>
      _call('listen', {'language': language, 'prompt': prompt, 'maxMs': maxMs});

  /// Sets the ringer or Do Not Disturb; `{ringer, dnd}` as they were before, or `{error}`.
  Future<Object?> soundMode(String mode) => _call('soundMode', {'mode': mode});

  /// Sets an alarm or timer in the clock app: `{opened}`, `{notified}` or `{error}`.
  Future<Object?> clock(Map<String, Object?> args) => _call('clock', args);

  // ---------------------------------------------------------------- in-app browser

  /// Loads [url] in browser [session] (made the first time, warm afterwards): `{url, title, slow?}` or `{error}`.
  Future<Object?> browserOpen(String session, String url, {bool fast = true, int timeoutMs = 30000}) =>
      _call('browserOpen', {'session': session, 'url': url, 'fast': fast, 'timeoutMs': timeoutMs});

  /// Runs JavaScript in the page; its result as JSON text, or null when the session is gone.
  Future<String?> browserEval(String session, String js) async {
    final r = await _call('browserEval', {'session': session, 'js': js});
    return r is String ? r : null;
  }

  Future<bool> browserBack(String session) async => await _call('browserBack', {'session': session}) == true;

  /// Saves the visible page as a PNG at [path] inside FlowDroid's folder.
  Future<Object?> browserScreenshot(String session, String path) =>
      _call('browserScreenshot', {'session': session, 'path': path});

  Future<Object?> browserShow(String session) => _call('browserShow', {'session': session});

  Future<Object?> browserHide(String session) => _call('browserHide', {'session': session});

  Future<Object?> browserClose(String session) => _call('browserClose', {'session': session});

  /// Opens [url] on screen to log in; `{url}` once the person taps Done, or `{error}`.
  Future<Object?> browserLogin(String url) => _call('browserLogin', {'url': url});

  /// The browser's cookies for [url], as a Cookie header value.
  Future<String> browserCookies(String url) async {
    final r = await _call('browserCookies', {'url': url});
    return r is String ? r : '';
  }

  /// Logs out of every site in the in-app browser.
  Future<Object?> browserClearLogins() => _call('browserClearLogins');

  /// A photo, gallery pick or scan: `{files: [paths], pdf?, cancelled?}` or `{error}`.
  Future<Object?> photo(String source, {bool multiple = false, int pages = 5, bool pdf = true}) =>
      _call('photo', {'source': source, 'multiple': multiple, 'pages': pages, 'pdf': pdf});

  Future<void> requestSms() => _channel.invokeMethod<void>('requestSms');

  Future<void> openNotificationAccess() => _channel.invokeMethod<void>('openNotificationAccess');

  /// Sends one SMS; returns an error message, or null when it was handed to the phone.
  Future<String?> sendSms(String to, String text) async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('sendSms', {'to': to, 'text': text});
      return map?['error'] as String?;
    } on MissingPluginException {
      return 'SMS can only be sent on Android';
    }
  }

  /// Starts reporting power, screen, battery and Wi-Fi changes as events (once per process).
  Future<void> watchPhoneEvents() async {
    try {
      await _channel.invokeMethod<void>('watchPhoneEvents');
    } on MissingPluginException {
      // Not on Android (tests): there are no phone events.
    }
  }

  static List<PhoneApp>? _apps;

  /// Installed apps: recent notification senders first, then by name. Cached for the session.
  Future<List<PhoneApp>> installedApps({bool refresh = false}) async {
    if (_apps != null && !refresh) return _apps!;
    try {
      final raw = await _channel.invokeListMethod<Object?>('installedApps') ?? const [];
      final apps =
          [
            for (final m in raw.whereType<Map<Object?, Object?>>())
              PhoneApp(
                package: m['package'] as String? ?? '',
                label: m['label'] as String? ?? '',
                icon: m['icon'] as Uint8List? ?? Uint8List(0),
                recentRank: m['recent'] as int? ?? -1,
              ),
          ]..sort((a, b) {
            if (a.recent != b.recent) return a.recent ? -1 : 1;
            if (a.recent) return a.recentRank.compareTo(b.recentRank);
            return a.label.toLowerCase().compareTo(b.label.toLowerCase());
          });
      return _apps = apps;
    } on MissingPluginException {
      return const [];
    }
  }

  /// Opens the contact chooser for a phone number or (with [email]) an email address.
  Future<PickedContact?> pickContact({bool email = false}) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('pickContact', {'kind': email ? 'email' : 'phone'});
      final value = m?['value'] as String?;
      if (value == null || value.isEmpty) return null;
      return (name: m?['name'] as String? ?? '', value: value);
    } on MissingPluginException {
      return null;
    }
  }

  /// Vibrates as an alarm, which Android allows from the background; an error message or null.
  Future<String?> vibrate(int ms) => _channel.invokeMethod<String>('vibrate', {'ms': ms});

  /// Opens [url], or (when Android blocks that in the background) posts a "Tap to open" notification.
  Future<Map<String, Object?>> openUrl(String url) async =>
      await _channel.invokeMapMethod<String, Object?>('openUrl', {'url': url}) ?? const {};

  Future<void> clipboardWrite(String text) => _channel.invokeMethod<void>('clipboardWrite', {'text': text});

  /// `{text}`, or `{error}` when FlowDroid isn't on screen (Android 10+).
  Future<Map<String, Object?>> clipboardRead() async =>
      await _channel.invokeMapMethod<String, Object?>('clipboardRead') ?? const {};

  /// Opens [path] (on this phone) in the app that handles [mime]; an error message or null.
  Future<String?> openFile(String path, String mime) async {
    try {
      return await _channel.invokeMethod<String>('openFile', {'path': path, 'mime': mime});
    } on MissingPluginException {
      return 'files can only be opened on Android';
    }
  }

  /// Offers [path] to other apps through the share sheet; an error message or null.
  Future<String?> shareFile(String path, String mime) async {
    try {
      return await _channel.invokeMethod<String>('shareFile', {'path': path, 'mime': mime});
    } on MissingPluginException {
      return 'files can only be shared on Android';
    }
  }

  /// Plays an audio file or URL to the end; returns an error message, or null when it played.
  Future<String?> playAudio(String source) async {
    try {
      return await _channel.invokeMethod<String>('playAudio', {'source': source});
    } on MissingPluginException {
      return 'audio can only be played on Android';
    }
  }

  Future<void> stopAudio() async {
    try {
      await _channel.invokeMethod<void>('stopAudio');
    } on MissingPluginException {
      // Not on Android.
    }
  }

  Future<BackgroundStatus> backgroundStatus() async {
    try {
      return BackgroundStatus.fromMap(await _channel.invokeMapMethod<String, Object?>('backgroundStatus') ?? const {});
    } on MissingPluginException {
      return const BackgroundStatus(batteryUnrestricted: true);
    }
  }

  /// Opens a system screen: `autostart` (the maker's launch manager), `battery`,
  /// `exactAlarms`, `notifications` or `app`. False when none could be opened.
  Future<bool> openBackgroundSettings(String kind) async =>
      await _channel.invokeMethod<bool>('openBackgroundSettings', {'kind': kind}) ?? false;

  /// Sets the wake-up alarm for [at] (null clears it); true when the alarm is exact.
  Future<bool> setWakeAlarm(DateTime? at) async {
    try {
      return await _channel.invokeMethod<bool>('setWakeAlarm', {'at': at?.millisecondsSinceEpoch ?? 0}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks the background service to start again, unless the user turned it off.
  Future<void> wakeService() async {
    try {
      await _channel.invokeMethod<void>('wakeService');
    } on MissingPluginException {
      // Not on Android.
    }
  }

  Future<Launch?> takeLaunch() async {
    final map = await _channel.invokeMapMethod<String, Object?>('takeLaunch');
    if (map == null) return null;
    return switch (map['type']) {
      'workflow' => WorkflowShortcut(map['workflowId'] as String? ?? ''),
      'share' => SharedContent(
        text: map['text'] as String?,
        subject: map['subject'] as String?,
        files: (map['files'] as List?)?.whereType<String>().toList() ?? const [],
      ),
      _ => null,
    };
  }

  /// Asks the launcher to add a home-screen icon that runs [workflowId].
  Future<bool> pinShortcut(String workflowId, String label) async =>
      await _channel.invokeMethod<bool>('pinShortcut', {'workflowId': workflowId, 'label': label}) ?? false;

  /// Lets the user pick a file; its bytes, or null when cancelled.
  Future<Uint8List?> openDocument() => _channel.invokeMethod<Uint8List>('openDocument');

  /// Lets the user choose where to save [bytes]; true when saved.
  Future<bool> saveDocument(String name, String mime, Uint8List bytes) async =>
      await _channel.invokeMethod<bool>('saveDocument', {'name': name, 'mime': mime, 'bytes': bytes}) ?? false;
}
