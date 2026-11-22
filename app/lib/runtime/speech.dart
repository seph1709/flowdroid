import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:phone_bridge/phone_bridge.dart';

import '../core/json.dart';
import '../data/credentials.dart';

/// A voice someone can choose.
class VoiceOption {
  const VoiceOption({
    required this.id,
    required this.name,
    this.detail = '',
    this.natural = false,
    this.online = false,
    this.previewUrl,
    this.locale = '',
  });

  /// What goes into the Voice parameter.
  final String id;
  final String name;

  /// e.g. `English (US) · female, warm`.
  final String detail;

  /// A modern, natural-sounding voice (neural / high quality).
  final bool natural;

  /// Needs the internet.
  final bool online;

  /// A free sample (ElevenLabs).
  final String? previewUrl;
  final String locale;
}

/// OpenAI's voices for `gpt-4o-mini-tts`, newest first.
const openAiVoices = <VoiceOption>[
  VoiceOption(id: 'marin', name: 'Marin', detail: 'Newest · natural, clear', natural: true, online: true),
  VoiceOption(id: 'cedar', name: 'Cedar', detail: 'Newest · natural, deep', natural: true, online: true),
  VoiceOption(id: 'coral', name: 'Coral', detail: 'Warm, friendly', natural: true, online: true),
  VoiceOption(id: 'sage', name: 'Sage', detail: 'Calm, measured', natural: true, online: true),
  VoiceOption(id: 'ash', name: 'Ash', detail: 'Clear, direct', natural: true, online: true),
  VoiceOption(id: 'ballad', name: 'Ballad', detail: 'Expressive, soft', natural: true, online: true),
  VoiceOption(id: 'verse', name: 'Verse', detail: 'Versatile, lively', natural: true, online: true),
  VoiceOption(id: 'nova', name: 'Nova', detail: 'Bright, upbeat', natural: true, online: true),
  VoiceOption(id: 'shimmer', name: 'Shimmer', detail: 'Light, gentle', natural: true, online: true),
  VoiceOption(id: 'alloy', name: 'Alloy', detail: 'Neutral', natural: true, online: true),
  VoiceOption(id: 'echo', name: 'Echo', detail: 'Low, even', natural: true, online: true),
  VoiceOption(id: 'fable', name: 'Fable', detail: 'Storyteller', natural: true, online: true),
  VoiceOption(id: 'onyx', name: 'Onyx', detail: 'Deep, authoritative', natural: true, online: true),
];

/// Speaks the Speak Text node's text with the phone's TTS or a cloud voice.
///
/// Cloud audio is cached by text and voice, so an announcement that repeats
/// ("Battery low") costs one request, not one per run.
class Speech {
  Speech({required this.credentials, required this.phone, required Directory dataDir, http.Client? client})
    : _cache = Directory('${dataDir.path}/cache/speech'),
      _client = client ?? http.Client();

  static const openAiModel = 'gpt-4o-mini-tts';
  static const elevenLabsModel = 'eleven_multilingual_v2';

  /// ElevenLabs' "Rachel", used when no voice is chosen.
  static const elevenLabsDefaultVoice = '21m00Tcm4TlvDq8BMAvC';
  static const _keepFiles = 40;

  final CredentialStore credentials;
  final PhoneBridge phone;
  final Directory _cache;
  final http.Client _client;
  final _tts = FlutterTts();

  Future<JsonMap> call(JsonMap effect) async {
    final text = asString(effect['text']).trim();
    if (text.isEmpty) return const {};
    try {
      final error = switch (asString(effect['provider'], 'phone')) {
        'openai' || 'elevenlabs' => await _cloud(effect, text),
        _ => await _phone(effect, text),
      };
      return error == null ? const {} : {'error': error};
    } on SocketException {
      return {'error': 'no internet connection for the cloud voice'};
    } on SpeechException catch (e) {
      return {'error': e.message};
    }
  }

  // ---- phone voices

  Future<String?> _phone(JsonMap effect, String text) async {
    await _tts.awaitSpeakCompletion(true);
    final voice = asString(effect['voice']);
    if (voice.isNotEmpty) {
      final match = (await phoneVoices()).where((v) => v.id == voice).firstOrNull;
      if (match == null) return 'the voice "$voice" is not installed on this phone';
      await _tts.setVoice({'name': match.id, 'locale': match.locale});
      await _tts.setLanguage(match.locale);
    }
    // flutter_tts on Android: 0.5 is normal speed.
    await _tts.setSpeechRate((asDouble(effect['speed'], 1) * 0.5).clamp(0.1, 1.0));
    await _tts.speak(text);
    return null;
  }

  /// Voices installed on the phone, natural (high-quality) ones first, then by language.
  Future<List<VoiceOption>> phoneVoices() async {
    final raw = await _tts.getVoices;
    final voices = <VoiceOption>[
      for (final v in (raw is List ? raw : const <Object?>[]).whereType<Map<Object?, Object?>>())
        () {
          final name = '${v['name'] ?? ''}';
          final locale = '${v['locale'] ?? ''}';
          final quality = '${v['quality'] ?? ''}';
          final online = '${v['network_required']}' == '1';
          // Google's newer voices are "very high" quality; network ones are also neural.
          final natural = quality.contains('very high') || quality == 'high' || online;
          return VoiceOption(
            id: name,
            name: _readableVoiceName(name, locale),
            detail: [_languageName(locale), if (online) 'online'].join(' · '),
            natural: natural,
            online: online,
            locale: locale,
          );
        }(),
    ];
    voices.sort((a, b) {
      final byLocale = a.locale.compareTo(b.locale);
      if (byLocale != 0) return byLocale;
      if (a.natural != b.natural) return a.natural ? -1 : 1;
      return a.id.compareTo(b.id);
    });
    return voices;
  }

  /// Speaks a short sample with a phone voice.
  Future<void> previewPhone(VoiceOption voice, {double speed = 1}) =>
      _phone({'voice': voice.id, 'speed': speed}, 'Hi! This is how I sound.');

  Future<void> stop() async {
    await _tts.stop();
    await phone.stopAudio();
  }

  // ---- cloud voices

  Future<String?> _cloud(JsonMap effect, String text) async {
    final file = await speakToFile(effect, text);
    return phone.playAudio(file.path);
  }

  /// The cloud voice's audio for [text], from the cache or freshly made.
  Future<File> speakToFile(JsonMap effect, String text) async {
    final provider = asString(effect['provider']);
    final key = sha1
        .convert(utf8.encode(jsonEncode([provider, effect['voice'], effect['speed'], effect['style'], text])))
        .toString();
    await _cache.create(recursive: true);
    final file = File('${_cache.path}/$key.mp3');
    if (await file.exists()) {
      await file.setLastModified(DateTime.now());
      return file;
    }
    final apiKey = await _key(asString(effect['credential']), provider);
    final bytes = provider == 'openai' ? await _openAi(effect, text, apiKey) : await _elevenLabs(effect, text, apiKey);
    await file.writeAsBytes(bytes);
    await _trimCache();
    return file;
  }

  Future<({String key, String base})> _key(String name, String provider) async {
    final credential = await credentials.byName(name);
    if (credential == null) throw SpeechException('credential "$name" not found; add it in Settings → Credentials');
    if (credential.type != provider) {
      throw SpeechException('credential "$name" is for ${credential.type}, not $provider');
    }
    final key = credential.values['apiKey'] ?? '';
    if (key.isEmpty) throw SpeechException('credential "$name" has no API key');
    final base = (credential.values['baseUrl'] ?? '').trim();
    return (key: key, base: base.isEmpty ? 'https://api.openai.com/v1' : base.replaceAll(RegExp(r'/+$'), ''));
  }

  Future<List<int>> _openAi(JsonMap effect, String text, ({String key, String base}) auth) async {
    final speed = asDouble(effect['speed'], 1);
    final style = [
      asString(effect['style']),
      // gpt-4o-mini-tts takes pace as an instruction rather than a number.
      if (speed != 1)
        speed > 1 ? 'Speak a little faster than usual (about ${speed}x).' : 'Speak slowly (about ${speed}x).',
    ].where((s) => s.isNotEmpty).join(' ');
    final response = await _client
        .post(
          Uri.parse('${auth.base}/audio/speech'),
          headers: {'Authorization': 'Bearer ${auth.key}', 'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': openAiModel,
            'voice': asString(effect['voice']).isEmpty ? 'coral' : effect['voice'],
            'input': text,
            'instructions': ?(style.isEmpty ? null : style),
            'response_format': 'mp3',
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw SpeechException('OpenAI voice failed: ${_apiError(response)}');
    return response.bodyBytes;
  }

  Future<List<int>> _elevenLabs(JsonMap effect, String text, ({String key, String base}) auth) async {
    final voice = asString(effect['voice']).isEmpty ? elevenLabsDefaultVoice : asString(effect['voice']);
    final response = await _client
        .post(
          Uri.parse('https://api.elevenlabs.io/v1/text-to-speech/$voice?output_format=mp3_44100_128'),
          headers: {'xi-api-key': auth.key, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'model_id': elevenLabsModel,
            // ElevenLabs accepts 0.7–1.2.
            'voice_settings': {'speed': asDouble(effect['speed'], 1).clamp(0.7, 1.2)},
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) throw SpeechException('ElevenLabs voice failed: ${_apiError(response)}');
    return response.bodyBytes;
  }

  /// The voices in an ElevenLabs account, with free samples.
  Future<List<VoiceOption>> elevenLabsVoices(String credentialName) async {
    final auth = await _key(credentialName, 'elevenlabs');
    final response = await _client
        .get(Uri.parse('https://api.elevenlabs.io/v1/voices'), headers: {'xi-api-key': auth.key})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw SpeechException('ElevenLabs: ${_apiError(response)}');
    return [
      for (final v in asMapList(asMap(jsonDecode(response.body))['voices']))
        VoiceOption(
          id: asString(v['voice_id']),
          name: asString(v['name']),
          detail: asMap(v['labels']).values.whereType<String>().where((s) => s.isNotEmpty).join(', '),
          natural: true,
          online: true,
          previewUrl: v['preview_url'] as String?,
        ),
    ];
  }

  static String _apiError(http.Response r) {
    try {
      final body = asMap(jsonDecode(r.body));
      final err = body['error'] ?? body['detail'];
      final message = err is Map ? asString(err['message'], asString(err['status'])) : asString(err);
      if (message.isNotEmpty) return 'HTTP ${r.statusCode}: $message';
    } on FormatException {
      // Not JSON.
    }
    return 'HTTP ${r.statusCode}';
  }

  Future<void> _trimCache() async {
    final files = await _cache.list().where((e) => e is File).cast<File>().toList();
    if (files.length <= _keepFiles) return;
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final f in files.skip(_keepFiles)) {
      await f.delete().catchError((Object _) => f);
    }
  }
}

class SpeechException implements Exception {
  const SpeechException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `en-us-x-tpf-local` → `TPF`; other engines' names are kept.
String _readableVoiceName(String name, String locale) {
  final google = RegExp(r'^[a-z]{2,3}-[a-z]{2,4}-x-([a-z0-9]+)-(local|network)$').firstMatch(name);
  if (google != null) return 'Voice ${google[1]!.toUpperCase()}';
  return name.isEmpty ? locale : name;
}

String _languageName(String locale) {
  const names = {
    'en': 'English', 'es': 'Spanish', 'fr': 'French', 'de': 'German', 'it': 'Italian', 'pt': 'Portuguese', //
    'ja': 'Japanese', 'ko': 'Korean', 'zh': 'Chinese', 'hi': 'Hindi', 'id': 'Indonesian', 'fil': 'Filipino',
    'tl': 'Filipino', 'ar': 'Arabic', 'ru': 'Russian', 'nl': 'Dutch', 'th': 'Thai', 'vi': 'Vietnamese',
    'tr': 'Turkish', 'pl': 'Polish', 'sv': 'Swedish', 'uk': 'Ukrainian', 'ms': 'Malay', 'bn': 'Bengali',
  };
  final parts = locale.split(RegExp('[-_]'));
  final lang = names[parts.first.toLowerCase()] ?? parts.first;
  return parts.length > 1 ? '$lang (${parts[1].toUpperCase()})' : lang;
}
