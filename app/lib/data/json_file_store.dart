import 'dart:convert';
import 'dart:io';

import '../core/json.dart';

/// JSON documents in a directory, one file per document.
/// Writes go to a temporary file first and are renamed into place, so a crash
/// never leaves a half-written document behind.
class JsonFileStore {
  JsonFileStore(this.directory);

  final Directory directory;

  File _file(String id) => File('${directory.path}/$id.json');

  Future<void> write(String id, JsonMap document) async {
    await directory.create(recursive: true);
    final target = _file(id);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(jsonEncode(document), flush: true);
    await temp.rename(target.path);
  }

  Future<JsonMap?> read(String id) async {
    final file = _file(id);
    if (!await file.exists()) return null;
    return _decode(await file.readAsString());
  }

  /// Every readable document; corrupt files are skipped rather than failing the list.
  Future<List<JsonMap>> readAll() async {
    if (!await directory.exists()) return [];
    final documents = <JsonMap>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final document = _decode(await entity.readAsString());
      if (document != null) documents.add(document);
    }
    return documents;
  }

  Future<void> delete(String id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteAll() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static JsonMap? _decode(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? asMap(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}
