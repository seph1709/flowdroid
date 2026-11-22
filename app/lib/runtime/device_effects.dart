import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:phone_bridge/phone_bridge.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';

import '../core/json.dart';
import 'effects.dart';
import 'http_effect.dart';
import 'linux/linux_runtime.dart';
import 'table_effect.dart';

/// Effects on a real Android device, backed by platform plugins.
///
/// Permission prompts need a visible screen. With [interactive] false (the
/// background service and WorkManager) a missing permission is reported as a
/// node error instead of prompting, which would crash without an activity.
class DeviceEffects extends EffectDispatcher {
  DeviceEffects({HttpEffect? http, this.tables, this.interactive = true, this.linux, this.phone, this.extra = const {}})
    : _http = http ?? HttpEffect();

  /// Native phone actions; null in tests.
  final PhoneBridge? phone;

  final bool interactive;

  static const _channel = AndroidNotificationDetails(
    'workflow_notifications',
    'Workflow notifications',
    channelDescription: 'Notifications posted by your workflows',
    importance: Importance.high,
    priority: Priority.high,
  );

  final HttpEffect _http;
  final TableEffect? tables;
  final LinuxRuntime? linux;

  /// More handlers, by effect type (Code, sub-workflows, agent tools, SMS, email, feeds, files).
  final Map<String, Future<JsonMap> Function(JsonMap effect)> extra;
  final _notifications = FlutterLocalNotificationsPlugin();
  final _tts = FlutterTts();
  final _battery = Battery();
  bool _notificationsReady = false;
  int _nextNotificationId = 0;

  @override
  late final Map<String, Future<JsonMap> Function(JsonMap effect)> handlers = {
    'http': _http.call,
    'wait': _wait,
    'notify': _notify,
    'speak': _speak,
    'vibrate': _vibrate,
    'openUrl': _openUrl,
    'clipboardWrite': _clipboardWrite,
    'clipboardRead': _clipboardRead,
    'battery': _readBattery,
    'location': _readLocation,
    'table': _table,
    'command': _command,
    ...extra,
  };

  Future<JsonMap> _table(JsonMap effect) async {
    final tables = this.tables;
    if (tables == null) return {'error': 'phone tables are not available here'};
    return tables(effect);
  }

  /// Runs each command on the phone or in the built-in Ubuntu, one result per command.
  Future<JsonMap> _command(JsonMap effect) async {
    final linux = this.linux;
    if (linux == null) return {'error': 'commands are not available here'};
    final results = <JsonMap>[];
    for (final c in asMapList(effect['commands'])) {
      final r = await linux.run(
        asString(c['command']),
        target: asString(c['target']) == 'ubuntu' ? LinuxTarget.ubuntu : LinuxTarget.phone,
        workdir: asString(c['workdir']),
        timeout: Duration(milliseconds: asInt(c['timeoutMs'], 60000)),
      );
      results.add(
        r.error != null ? {'error': r.error} : {'exitCode': r.exitCode, 'stdout': r.stdout, 'stderr': r.stderr},
      );
    }
    return {'results': results};
  }

  Future<JsonMap> _wait(JsonMap effect) async {
    await Future<void>.delayed(Duration(milliseconds: asInt(effect['ms'])));
    return const {};
  }

  Future<JsonMap> _notify(JsonMap effect) async {
    await _ensureNotifications();
    for (final n in asMapList(effect['notifications'])) {
      await _notifications.show(
        id: _nextNotificationId++,
        title: asString(n['title']),
        body: asString(n['body']),
        notificationDetails: const NotificationDetails(android: _channel),
      );
    }
    return const {};
  }

  Future<void> _ensureNotifications() async {
    if (_notificationsReady) return;
    await _notifications.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@drawable/ic_stat_flow')),
    );
    final android = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (interactive) await android?.requestNotificationsPermission();
    _notificationsReady = true;
  }

  Future<JsonMap> _speak(JsonMap effect) async {
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(asString(effect['text']));
    return const {};
  }

  Future<JsonMap> _vibrate(JsonMap effect) async {
    final phone = this.phone;
    if (phone != null) {
      final error = await phone.vibrate(asInt(effect['ms'], 500));
      return error == null ? const {} : {'error': error};
    }
    if (await Vibration.hasVibrator()) await Vibration.vibrate(duration: asInt(effect['ms'], 500));
    return const {};
  }

  Future<JsonMap> _openUrl(JsonMap effect) async {
    final uri = Uri.tryParse(asString(effect['url']));
    if (uri == null || !uri.hasScheme) return {'error': 'invalid URL ${effect['url']}'};
    final phone = this.phone;
    if (phone != null) {
      final r = await phone.openUrl(uri.toString());
      if (r['error'] case final String error) return {'error': error};
      // Shown as a notification when Android blocked opening it from the background.
      return {'opened': r['opened'] == true, 'notified': r['notified'] == true};
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    return opened ? const {} : {'error': 'no app can open $uri'};
  }

  Future<JsonMap> _clipboardWrite(JsonMap effect) async {
    final phone = this.phone;
    if (phone != null) {
      await phone.clipboardWrite(asString(effect['text']));
      return const {};
    }
    await Clipboard.setData(ClipboardData(text: asString(effect['text'])));
    return const {};
  }

  Future<JsonMap> _clipboardRead(JsonMap effect) async {
    final phone = this.phone;
    if (phone != null) {
      final r = await phone.clipboardRead();
      if (r['error'] case final String error) return {'error': error};
      return {'text': asString(r['text'])};
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return {'text': data?.text ?? ''};
  }

  Future<JsonMap> _readBattery(JsonMap effect) async {
    final level = await _battery.batteryLevel;
    final state = await _battery.batteryState;
    return {'level': level, 'charging': state == BatteryState.charging || state == BatteryState.full};
  }

  Future<JsonMap> _readLocation(JsonMap effect) async {
    if (!await Geolocator.isLocationServiceEnabled()) return {'error': 'location services are off'};
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && interactive) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return {
        'error': interactive
            ? 'location permission denied'
            : 'location permission not granted; open FlowDroid once to allow it',
      };
    }
    // "While using the app" isn't enough while FlowDroid is in the background.
    if (!interactive && permission != LocationPermission.always) {
      return {
        'error':
            'reading the location in the background needs “Allow all the time”: Settings → Phone access → Location',
      };
    }
    final Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 30)),
      );
    } on TimeoutException {
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return {'error': 'no location fix within 30 s (indoors, or location is off)'};
      return {
        'latitude': last.latitude,
        'longitude': last.longitude,
        'accuracy': last.accuracy,
        'stale': true,
        'at': last.timestamp.toUtc().toIso8601String(),
      };
    }
    return {'latitude': position.latitude, 'longitude': position.longitude, 'accuracy': position.accuracy};
  }
}
