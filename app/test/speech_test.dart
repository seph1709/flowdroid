import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/speech.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phone_bridge/phone_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  Future<(Speech, List<http.Request>)> speech(http.Response Function(http.Request) reply) async {
    final store = CredentialStore();
    await store.save(const Credential(name: 'oa', type: 'openai', values: {'apiKey': 'sk-1'}));
    await store.save(const Credential(name: 'el', type: 'elevenlabs', values: {'apiKey': 'xi-1'}));
    final sent = <http.Request>[];
    final client = MockClient((r) async {
      sent.add(r);
      return reply(r);
    });
    final dir = await Directory.systemTemp.createTemp('speech');
    return (Speech(credentials: store, phone: PhoneBridge(), dataDir: dir, client: client), sent);
  }

  test('OpenAI voices: model, voice, style and pace; repeats come from the cache', () async {
    final (s, sent) = await speech((_) => http.Response.bytes([1, 2, 3], 200));
    final effect = {'provider': 'openai', 'credential': 'oa', 'voice': 'marin', 'style': 'calm', 'speed': 1.25};
    final file = await s.speakToFile(effect, 'Battery low');
    expect(await file.readAsBytes(), [1, 2, 3]);
    final body = jsonDecode(sent.single.body) as Map;
    expect(sent.single.url.toString(), 'https://api.openai.com/v1/audio/speech');
    expect(sent.single.headers['Authorization'], 'Bearer sk-1');
    expect(body['model'], 'gpt-4o-mini-tts');
    expect(body['voice'], 'marin');
    expect(body['input'], 'Battery low');
    expect(body['instructions'], contains('calm'));
    expect(body['instructions'], contains('faster'));

    await s.speakToFile(effect, 'Battery low');
    expect(sent, hasLength(1), reason: 'same text and voice: cached');
    await s.speakToFile({...effect, 'voice': 'cedar'}, 'Battery low');
    expect(sent, hasLength(2));
  });

  test('ElevenLabs: default voice, clamped speed, voice list with samples', () async {
    final (s, sent) = await speech((r) {
      if (r.url.path == '/v1/voices') {
        return http.Response(
          jsonEncode({
            'voices': [
              {'voice_id': 'v1', 'name': 'Aria', 'labels': {'accent': 'American', 'gender': 'female'}, 'preview_url': 'https://x/a.mp3'},
            ],
          }),
          200,
        );
      }
      return http.Response.bytes([9], 200);
    });
    await s.speakToFile({'provider': 'elevenlabs', 'credential': 'el', 'speed': 2}, 'Hi');
    expect(sent.single.url.path, '/v1/text-to-speech/${Speech.elevenLabsDefaultVoice}');
    expect(sent.single.headers['xi-api-key'], 'xi-1');
    expect((jsonDecode(sent.single.body) as Map)['voice_settings'], {'speed': 1.2});

    final voices = await s.elevenLabsVoices('el');
    expect(voices.single.name, 'Aria');
    expect(voices.single.detail, 'American, female');
    expect(voices.single.previewUrl, 'https://x/a.mp3');
  });

  test('clear errors: wrong credential, API refusal', () async {
    final (s, _) = await speech((_) => http.Response(jsonEncode({'error': {'message': 'Invalid API key'}}), 401));
    expect(await s.call({'type': 'speak', 'text': 'x', 'provider': 'openai', 'credential': 'el'}), {
      'error': 'credential "el" is for elevenlabs, not openai',
    });
    expect(await s.call({'type': 'speak', 'text': 'x', 'provider': 'openai', 'credential': 'nope'}), {
      'error': 'credential "nope" not found; add it in Settings → Credentials',
    });
    expect(await s.call({'type': 'speak', 'text': 'x', 'provider': 'openai', 'credential': 'oa'}), {
      'error': 'OpenAI voice failed: HTTP 401: Invalid API key',
    });
    expect(await s.call({'type': 'speak', 'text': '  '}), isEmpty, reason: 'nothing to say');
  });

  test('every OpenAI voice is unique and described', () {
    expect(openAiVoices.map((v) => v.id).toSet(), hasLength(openAiVoices.length));
    expect(openAiVoices.every((v) => v.detail.isNotEmpty && v.natural), isTrue);
  });
}
