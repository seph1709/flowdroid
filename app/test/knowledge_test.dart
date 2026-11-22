import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/data/credentials.dart';
import 'package:flowdroid/runtime/knowledge_base.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('chunking', () {
    test('short text is one chunk; long text splits at paragraphs and sentences', () {
      expect(chunkText('  Hello there. '), ['Hello there.']);
      final paras = List.generate(6, (i) => 'Paragraph $i. ${'word ' * 30}'.trim()).join('\n\n');
      final chunks = chunkText(paras, size: 400, overlap: 50);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.length <= 400 + 50 + 2), isTrue);
      // Each chunk after the first starts with the end of the one before.
      expect(chunks[1].startsWith(chunks[0].substring(chunks[0].length - 20).trim().split(' ').last), isTrue);
    });

    test('a giant word is cut instead of breaking the limit', () {
      final chunks = chunkText('x' * 2500, size: 1000, overlap: 0);
      expect(chunks.map((c) => c.length), [1000, 1000, 500]);
    });
  });

  test('word ranking prefers chunks with rare query words', () {
    final chunks = [
      Chunk(source: 'a', index: 0, text: 'The wifi password is written under the router.'),
      Chunk(source: 'b', index: 0, text: 'Dinner is at seven. The router is in the hall.'),
      Chunk(source: 'c', index: 0, text: 'Buy milk and eggs.'),
    ];
    final ranked = rankByWords(chunks, 'What is the wifi password?');
    expect(ranked.first.$1.source, 'a');
    expect(ranked.first.$2, inInclusiveRange(0, 1));
    expect(ranked.map((r) => r.$1.source), isNot(contains('c')));
    // Every important word of the question is in the first chunk.
    expect(ranked.first.$2, greaterThan(0.9));
    expect(rankByWords(chunks, 'where is the router').first.$2, 1.0);
  });

  Future<KnowledgeBase> kb([http.Client? client]) async {
    final store = CredentialStore();
    await store.save(const Credential(name: 'oa', type: 'openai', values: {'apiKey': 'sk'}));
    return KnowledgeBase(dataDir: await Directory.systemTemp.createTemp('kb'), credentials: store, client: client);
  }

  test('add, search, replace a source, list, delete — offline words', () async {
    final k = await kb();
    Map<String, Object?> add(String source, String text) => {
      'op': 'add', 'collection': 'Home notes', 'embedder': 'local', 'chunkSize': 800, 'overlap': 100,
      'documents': [
        {'text': text, 'source': source},
      ],
    };
    expect(await k.call(add('wifi', 'The wifi password is hunter2.')), {
      'added': [
        {'source': 'wifi', 'chunks': 1, 'characters': 29},
      ],
    });
    await k.call(add('trash', 'Trash goes out on Tuesday night.'));
    final r = await k.call({
      'op': 'search', 'collection': 'Home notes',
      'queries': [
        {'query': 'wifi password', 'topK': 3, 'minScore': 0},
      ],
    });
    final first = (r['results']! as List).first as Map;
    expect(((first['matches'] as List).first as Map)['source'], 'wifi');
    expect(first['context'], contains('hunter2'));

    // Same source again: replaced, not duplicated.
    await k.call(add('wifi', 'The wifi password changed to correcthorse.'));
    expect((await k.sources('Home notes')).map((s) => s['source']), unorderedEquals(['wifi', 'trash']));
    final again = await k.call({
      'op': 'search', 'collection': 'Home notes',
      'queries': [
        {'query': 'wifi password', 'topK': 3, 'minScore': 0},
      ],
    });
    expect(jsonEncode(again), isNot(contains('hunter2')));

    expect((await k.collections()).single, containsPair('chunks', 2));
    expect(await k.deleteSource('Home notes', 'trash'), 1);
    await k.clear('Home notes');
    expect(await k.collections(), isEmpty);
    expect((await k.call({'op': 'search', 'collection': 'Home notes', 'queries': []}))['error'], contains('no knowledge base'));
  });

  test('embeddings: stored with the collection, used for search, same kind enforced', () async {
    final sent = <Map<String, Object?>>[];
    final client = MockClient((r) async {
      final body = jsonDecode(r.body) as Map<String, Object?>;
      sent.add(body);
      final input = (body['input']! as List).cast<String>();
      // A toy embedding: [mentions cats, mentions dogs].
      return http.Response(
        jsonEncode({
          'data': [
            for (final (i, t) in input.indexed)
              {'index': i, 'embedding': [t.contains('cat') ? 1.0 : 0.0, t.contains('dog') ? 1.0 : 0.0, 0.1]},
          ],
        }),
        200,
      );
    });
    final k = await kb(client);
    await k.call({
      'op': 'add', 'collection': 'pets', 'embedder': 'openai', 'credential': 'oa', 'chunkSize': 800, 'overlap': 0,
      'documents': [
        {'text': 'My cat sleeps all day.', 'source': 'cat'},
        {'text': 'The dog needs a walk.', 'source': 'dog'},
      ],
    });
    expect(sent.single['model'], 'text-embedding-3-small');
    // The search needs no credential: the knowledge base remembers it.
    final r = await k.call({
      'op': 'search', 'collection': 'pets',
      'queries': [
        {'query': 'where is the cat?', 'topK': 1, 'minScore': 0},
      ],
    });
    expect(((((r['results']! as List).first as Map)['matches'] as List).single as Map)['source'], 'cat');
    final mixed = await k.call({
      'op': 'add', 'collection': 'pets', 'embedder': 'local', 'chunkSize': 800, 'overlap': 0,
      'documents': [
        {'text': 'x', 'source': 'x'},
      ],
    });
    expect(mixed['error'], contains('searches by OpenAI embeddings'));
  });
}
