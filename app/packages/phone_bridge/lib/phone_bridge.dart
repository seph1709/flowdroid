import 'dart:async';

import 'package:flutter/services.dart';

/// Which phone features FlowDroid may use.
class PhoneAccess {
  const PhoneAccess({required this.sms, required this.notificationAccess});

  final bool sms;
  final bool notificationAccess;
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
    return PhoneAccess(sms: map['sms'] == true, notificationAccess: map['notificationAccess'] == true);
  }

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
      final apps = [
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
      return BackgroundStatus.fromMap(
        await _channel.invokeMapMethod<String, Object?>('backgroundStatus') ?? const {},
      );
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
