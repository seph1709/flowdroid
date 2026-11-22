import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../data/credentials.dart';

/// Default embedding model per provider.
const defaultEmbeddingModels = {
  'openai': 'text-embedding-3-small',
  'gemini': 'text-embedding-004',
  'openaiCompatible': 'nomic-embed-text',
};

/// Splits [text] into chunks of about [size] characters at paragraph, then
/// sentence, then word boundaries; each chunk starts with the last [overlap]
/// characters of the one before, so an answer split across two chunks is found.
List<String> chunkText(String text, {int size = 800, int overlap = 100}) {
  final clean = text.replaceAll('\r\n', '\n').replaceAll(RegExp(r'[ \t]+'), ' ').trim();
  if (clean.isEmpty) return const [];
  if (clean.length <= size) return [clean];
  // Pieces no longer than size: paragraphs, else sentences, else words.
  final pieces = <String>[];
  for (final para in clean.split(RegExp(r'\n\s*\n'))) {
    final p = para.trim();
    if (p.isEmpty) continue;
    if (p.length <= size) {
      pieces.add(p);
      continue;
    }
    for (final sentence in p.split(RegExp(r'(?<=[.!?。！？])\s+'))) {
      if (sentence.length <= size) {
        pieces.add(sentence);
        continue;
      }
      var line = StringBuffer();
      for (final word in sentence.split(' ')) {
        if (line.length + word.length + 1 > size && line.isNotEmpty) {
          pieces.add('$line');
          line = StringBuffer();
        }
        // A single huge "word" (a URL, base64) is cut where it must be.
        for (var w = word; w.isNotEmpty;) {
          final take = math.min(w.length, size);
          if (line.isNotEmpty) line.write(' ');
          line.write(w.substring(0, take));
          w = w.substring(take);
          if (w.isNotEmpty) {
            pieces.add('$line');
            line = StringBuffer();
          }
        }
      }
      if (line.isNotEmpty) pieces.add('$line');
    }
  }
  final chunks = <String>[];
  var current = StringBuffer();
  for (final piece in pieces) {
    if (current.isNotEmpty && current.length + piece.length + 2 > size) {
      final done = '$current';
      chunks.add(done);
      current = StringBuffer(_tail(done, overlap));
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(piece);
  }
  if (current.isNotEmpty) chunks.add('$current');
  return chunks;
}

/// The last [n] characters of [s], starting at a word.
String _tail(String s, int n) {
  if (n <= 0) return '';
  if (s.length <= n) return s;
  final cut = s.substring(s.length - n);
  final space = cut.indexOf(' ');
  return (space > 0 && space < cut.length - 1 ? cut.substring(space + 1) : cut).trim();
}

const _stopwords = {
  'a', 'an', 'the', 'and', 'or', 'of', 'to', 'in', 'on', 'at', 'is', 'are', 'was', 'were', 'be', 'it', 'its', //
  'for', 'with', 'as', 'by', 'that', 'this', 'from', 'what', 'which', 'who', 'how', 'do', 'does', 'did', 'i',
  'you', 'my', 'me', 'we', 'our', 'your', 'can', 'will', 'there', 'their', 'if', 'so', 'not', 'no', 'but',
  'where', 'when', 'why', 'whats', 'tell', 'about', 'please', 'any', 'some', 'have', 'has', 'had',
};

/// Lower-case words and numbers, without very common words.
List<String> tokenize(String text) => [
  for (final m in RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text.toLowerCase()))
    if (m[0]!.length > 1 && !_stopwords.contains(m[0])) m[0]!,
];

/// One stored chunk.
class Chunk {
  Chunk({required this.source, required this.index, required this.text, this.vector});

  factory Chunk.fromJson(JsonMap j) => Chunk(
    source: asString(j['source']),
    index: asInt(j['i']),
    text: asString(j['text']),
    vector: j['v'] is String ? Float32List.view(base64.decode(j['v']! as String).buffer) : null,
  );

  final String source;
  final int index;
  final String text;
  final Float32List? vector;

  List<String>? _tokens;
  List<String> get tokens => _tokens ??= tokenize(text);

  JsonMap toJson() => {
    'source': source,
    'i': index,
    'text': text,
    if (vector != null) 'v': base64.encode(vector!.buffer.asUint8List()),
  };
}

/// Ranks [chunks] for [query] by words (BM25). The score shown is how much of
/// the question the chunk covers, each word weighted by how rare it is (0–1),
/// so a chunk with every important word scores near 1.
List<(Chunk, double)> rankByWords(List<Chunk> chunks, String query) {
  final terms = tokenize(query).toSet();
  if (terms.isEmpty || chunks.isEmpty) return const [];
  final n = chunks.length;
  final avg = chunks.fold<int>(0, (s, c) => s + c.tokens.length) / n;
  final df = {for (final t in terms) t: chunks.where((c) => c.tokens.contains(t)).length};
  double idf(String t) => math.log(1 + (n - df[t]! + 0.5) / (df[t]! + 0.5));
  // Words in no chunk at all still count against coverage, a little.
  double weight(String t) => df[t] == 0 ? 0.5 : idf(t);
  final total = terms.fold<double>(0, (s, t) => s + weight(t));
  const k1 = 1.2, b = 0.75;
  final out = <(Chunk, double, double)>[];
  for (final c in chunks) {
    var bm25 = 0.0;
    var covered = 0.0;
    for (final t in terms) {
      final tf = c.tokens.where((w) => w == t).length;
      if (tf == 0) continue;
      covered += weight(t);
      bm25 += idf(t) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * c.tokens.length / (avg == 0 ? 1 : avg)));
    }
    if (covered > 0) out.add((c, bm25, total == 0 ? 0 : (covered / total).clamp(0, 1).toDouble()));
  }
  out.sort((x, y) => y.$2 != x.$2 ? y.$2.compareTo(x.$2) : y.$3.compareTo(x.$3));
  return [for (final (c, _, score) in out) (c, score)];
}

double cosine(Float32List a, Float32List b) {
  if (a.length != b.length) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na == 0 || nb == 0 ? 0 : dot / (math.sqrt(na) * math.sqrt(nb));
}

class KnowledgeException implements Exception {
  const KnowledgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The `knowledge` effect: knowledge bases stored on the phone, one folder each
/// (`meta.json` and `chunks.jsonl`), searched by words or by embeddings.
class KnowledgeBase {
  KnowledgeBase({required Directory dataDir, required this.credentials, http.Client? client})
    : root = Directory('${dataDir.path}/knowledge'),
      _client = client ?? http.Client();

  final Directory root;
  final CredentialStore credentials;
  final http.Client _client;
  final _cache = <String, (DateTime, List<Chunk>)>{};

  Future<JsonMap> call(JsonMap effect) async {
    try {
      return switch (asString(effect['op'])) {
        'add' => await _add(effect),
        'search' => await _search(effect),
        'collections' => {'rows': await collections()},
        'sources' => {'rows': await sources(asString(effect['collection']))},
        'deleteSource' => {
          'rows': [
            {'deleted': await deleteSource(asString(effect['collection']), asString(effect['source']))},
          ],
        },
        'clear' => {
          'rows': [
            {'cleared': await clear(asString(effect['collection']))},
          ],
        },
        final op => {'error': 'unknown knowledge operation $op'},
      };
    } on KnowledgeException catch (e) {
      return {'error': e.message};
    } on SocketException {
      return {'error': 'no internet connection for the embeddings'};
    }
  }

  /// Folder name for a knowledge base; any name works, unsafe characters become "_".
  Directory _dir(String name) {
    final safe = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') throw const KnowledgeException('knowledge base name is required');
    return Directory('${root.path}/$safe');
  }

  Future<JsonMap?> _meta(String name) async {
    final f = File('${_dir(name).path}/meta.json');
    if (!await f.exists()) return null;
    return asMap(jsonDecode(await f.readAsString()));
  }

  Future<List<Chunk>> _chunks(String name) async {
    final f = File('${_dir(name).path}/chunks.jsonl');
    if (!await f.exists()) return [];
    final modified = await f.lastModified();
    final cached = _cache[f.path];
    if (cached != null && cached.$1 == modified) return cached.$2;
    final chunks = [
      for (final line in await f.readAsLines())
        if (line.trim().isNotEmpty) Chunk.fromJson(asMap(jsonDecode(line))),
    ];
    _cache[f.path] = (modified, chunks);
    return chunks;
  }

  Future<void> _save(String name, List<Chunk> chunks) async {
    final dir = _dir(name);
    await dir.create(recursive: true);
    final f = File('${dir.path}/chunks.jsonl');
    final temp = File('${f.path}.tmp');
    await temp.writeAsString(chunks.map((c) => jsonEncode(c.toJson())).join('\n'));
    await temp.rename(f.path);
    _cache.remove(f.path);
  }

  Future<JsonMap> _add(JsonMap effect) async {
    final name = asString(effect['collection']);
    final embedder = asString(effect['embedder'], 'local');
    var meta = await _meta(name);
    if (meta != null && asString(meta['embedder']) != embedder) {
      throw KnowledgeException(
        'knowledge base "$name" searches by ${_kindName(asString(meta['embedder']))}; '
        'use that here too, or add to a new knowledge base',
      );
    }
    final model = asString(effect['model'], asString(meta?['model'], defaultEmbeddingModels[embedder] ?? ''));
    final credential = asString(effect['credential'], asString(meta?['credential']));
    final size = asInt(effect['chunkSize'], 800);
    final overlap = asInt(effect['overlap'], 100);
    final chunks = await _chunks(name);
    final added = <JsonMap>[];
    final fresh = <Chunk>[];
    final replaced = <String>{};
    for (final (i, doc) in asMapList(effect['documents']).indexed) {
      final source = asString(doc['source']).isEmpty
          ? 'item ${i + 1} · ${DateTime.now().toIso8601String()}'
          : asString(doc['source']);
      final pieces = chunkText(asString(doc['text']), size: size, overlap: overlap);
      replaced.add(source);
      fresh.addAll([for (final (j, t) in pieces.indexed) Chunk(source: source, index: j, text: t)]);
      added.add({'source': source, 'chunks': pieces.length, 'characters': asString(doc['text']).length});
    }
    var vectors = <Float32List>[];
    if (embedder != 'local' && fresh.isNotEmpty) {
      vectors = await embed(embedder, credential, model, [for (final c in fresh) c.text]);
      if (meta != null && meta['dimensions'] != null && vectors.first.length != asInt(meta['dimensions'])) {
        throw KnowledgeException('the embedding model changed size; use "${meta['model']}" for "$name"');
      }
    }
    final kept = chunks.where((c) => !replaced.contains(c.source)).toList();
    final stored = [
      ...kept,
      for (final (i, c) in fresh.indexed)
        Chunk(source: c.source, index: c.index, text: c.text, vector: vectors.isEmpty ? null : vectors[i]),
    ];
    await _save(name, stored);
    meta = {
      'name': name,
      'embedder': embedder,
      if (embedder != 'local') ...{
        'model': model,
        'credential': credential,
        'dimensions': vectors.firstOrNull?.length ?? meta?['dimensions'],
      },
      'createdAt': meta?['createdAt'] ?? DateTime.now().toUtc().toIso8601String(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await File('${_dir(name).path}/meta.json').writeAsString(jsonEncode(meta));
    return {'added': added};
  }

  Future<JsonMap> _search(JsonMap effect) async {
    final name = asString(effect['collection']);
    final meta = await _meta(name);
    if (meta == null) throw KnowledgeException('there is no knowledge base "$name" yet: add something to it first');
    final chunks = await _chunks(name);
    final embedder = asString(meta['embedder'], 'local');
    final queries = asMapList(effect['queries']);
    List<Float32List> qv = const [];
    if (embedder != 'local' && queries.isNotEmpty) {
      qv = await embed(
        embedder,
        asString(effect['credential'], asString(meta['credential'])),
        asString(meta['model'], defaultEmbeddingModels[embedder] ?? ''),
        [for (final q in queries) asString(q['query'])],
      );
    }
    final results = <JsonMap>[];
    for (final (i, q) in queries.indexed) {
      final ranked = embedder == 'local'
          ? rankByWords(chunks, asString(q['query']))
          : ([
              for (final c in chunks)
                if (c.vector != null) (c, cosine(qv[i], c.vector!).clamp(0, 1).toDouble()),
            ]..sort((x, y) => y.$2.compareTo(x.$2)));
      final top = ranked.where((r) => r.$2 >= asDouble(q['minScore'])).take(asInt(q['topK'], 4)).toList();
      results.add({
        'matches': [
          for (final (c, s) in top)
            {'text': c.text, 'score': (s * 1000).round() / 1000, 'source': c.source, 'chunk': c.index},
        ],
        'context': [for (final (c, _) in top) '[${c.source}]\n${c.text}'].join('\n\n---\n\n'),
        'found': top.length,
      });
    }
    return {'results': results};
  }

  Future<List<JsonMap>> collections() async {
    if (!await root.exists()) return [];
    final out = <JsonMap>[];
    await for (final dir in root.list()) {
      if (dir is! Directory) continue;
      final metaFile = File('${dir.path}/meta.json');
      if (!await metaFile.exists()) continue;
      final meta = asMap(jsonDecode(await metaFile.readAsString()));
      final chunks = await _chunks(asString(meta['name']));
      final chunkFile = File('${dir.path}/chunks.jsonl');
      out.add({
        'name': meta['name'],
        'searchBy': _kindName(asString(meta['embedder'])),
        if (meta['model'] != null) 'model': meta['model'],
        'sources': chunks.map((c) => c.source).toSet().length,
        'chunks': chunks.length,
        'sizeKb': await chunkFile.exists() ? ((await chunkFile.length()) / 1024).ceil() : 0,
        'updatedAt': meta['updatedAt'],
      });
    }
    return out..sort((a, b) => asString(a['name']).compareTo(asString(b['name'])));
  }

  Future<List<JsonMap>> sources(String name) async {
    final by = <String, (int, int)>{};
    for (final c in await _chunks(name)) {
      final (n, chars) = by[c.source] ?? (0, 0);
      by[c.source] = (n + 1, chars + c.text.length);
    }
    return [
      for (final MapEntry(:key, :value) in by.entries) {'source': key, 'chunks': value.$1, 'characters': value.$2},
    ];
  }

  Future<int> deleteSource(String name, String source) async {
    final chunks = await _chunks(name);
    final kept = chunks.where((c) => c.source != source).toList();
    if (kept.length != chunks.length) await _save(name, kept);
    return chunks.length - kept.length;
  }

  Future<String> clear(String name) async {
    final dir = _dir(name);
    if (await dir.exists()) await dir.delete(recursive: true);
    _cache.removeWhere((k, _) => k.startsWith(dir.path));
    return name;
  }

  static String _kindName(String embedder) => switch (embedder) {
    'local' => 'words',
    'openai' => 'OpenAI embeddings',
    'gemini' => 'Gemini embeddings',
    'openaiCompatible' => 'embeddings from your server',
    _ => embedder,
  };

  /// Embeddings for [texts], in order, in batches.
  Future<List<Float32List>> embed(String provider, String credentialName, String model, List<String> texts) async {
    if (credentialName.isEmpty) throw const KnowledgeException('choose a credential for the embeddings');
    final credential = await credentials.byName(credentialName);
    if (credential == null) {
      throw KnowledgeException('credential "$credentialName" not found; add it in Settings → Credentials');
    }
    final key = credential.values['apiKey'] ?? '';
    final base = (credential.values['baseUrl'] ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    final out = <Float32List>[];
    const batch = 64;
    for (var i = 0; i < texts.length; i += batch) {
      final part = texts.sublist(i, math.min(i + batch, texts.length));
      out.addAll(switch (provider) {
        'gemini' => await _gemini(key, model, part),
        _ => await _openAi(provider == 'openai' && base.isEmpty ? 'https://api.openai.com/v1' : base, key, model, part),
      });
    }
    return out;
  }

  Future<List<Float32List>> _openAi(String base, String key, String model, List<String> texts) async {
    if (base.isEmpty) throw const KnowledgeException('the credential needs a Base URL for embeddings');
    final r = await _client
        .post(
          Uri.parse('$base/embeddings'),
          headers: {'Content-Type': 'application/json', if (key.isNotEmpty) 'Authorization': 'Bearer $key'},
          body: jsonEncode({'model': model, 'input': texts}),
        )
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) throw KnowledgeException('embeddings failed: ${_apiError(r)}');
    final data = asMapList(asMap(jsonDecode(r.body))['data'])
      ..sort((a, b) => asInt(a['index']).compareTo(asInt(b['index'])));
    return [for (final d in data) Float32List.fromList(asList(d['embedding']).map((v) => asDouble(v)).toList())];
  }

  Future<List<Float32List>> _gemini(String key, String model, List<String> texts) async {
    final r = await _client
        .post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:batchEmbedContents'),
          headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
          body: jsonEncode({
            'requests': [
              for (final t in texts)
                {
                  'model': 'models/$model',
                  'content': {
                    'parts': [
                      {'text': t},
                    ],
                  },
                },
            ],
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) throw KnowledgeException('embeddings failed: ${_apiError(r)}');
    return [
      for (final e in asMapList(asMap(jsonDecode(r.body))['embeddings']))
        Float32List.fromList(asList(e['values']).map((v) => asDouble(v)).toList()),
    ];
  }

  static String _apiError(http.Response r) {
    try {
      final err = asMap(jsonDecode(r.body))['error'];
      final message = err is Map ? asString(err['message']) : asString(err);
      if (message.isNotEmpty) return 'HTTP ${r.statusCode}: $message';
    } on FormatException {
      // Not JSON.
    }
    return 'HTTP ${r.statusCode}';
  }
}
