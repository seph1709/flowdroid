import 'dart:io';

import '../core/json.dart';

/// Media types by extension; matches `file_refs.ts`, plus a few more for previews.
const _types = {
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', //
  'heic': 'image/heic', 'pdf': 'application/pdf', 'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv',
  'json': 'application/json', 'html': 'text/html', 'htm': 'text/html', 'xml': 'application/xml',
  'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'wav': 'audio/wav', 'ogg': 'audio/ogg', 'mp4': 'video/mp4',
  'zip': 'application/zip', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'log': 'text/plain', 'yaml': 'text/yaml', 'yml': 'text/yaml', 'tsv': 'text/tab-separated-values',
};

String mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  return _types[dot < 0 ? '' : name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
}

/// Files whose bytes are text, so they can be read straight into a step.
bool isTextMime(String mime) => mime.startsWith('text/') || mime == 'application/json' || mime == 'application/xml';

class FileStoreException implements Exception {
  const FileStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// FlowDroid's files folder (Ubuntu sees it as /root/files). Steps refer to
/// files by paths inside it; a reference is `{path, name, mimeType, size}`.
class FileStore {
  FileStore(Directory dataDir) : root = Directory('${dataDir.path}/files');

  final Directory root;

  /// The file at [path] (relative to the folder; `/root/files/…` from Ubuntu also works).
  File resolve(String path) {
    var p = path.trim();
    if (p.startsWith('/root/files/')) p = p.substring('/root/files/'.length);
    if (p.startsWith(root.path)) p = p.substring(root.path.length);
    p = p.replaceAll(RegExp(r'^/+'), '');
    final parts = <String>[];
    for (final part in p.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') throw FileStoreException('"$path" points outside FlowDroid’s folder');
      parts.add(part);
    }
    if (parts.isEmpty) throw const FileStoreException('file path is empty');
    return File('${root.path}/${parts.join('/')}');
  }

  /// [path] after checking the file exists.
  Future<File> existing(String path) async {
    final f = resolve(path);
    if (!await f.exists()) throw FileStoreException('file not found: $path');
    return f;
  }

  String relative(File f) => f.path.substring(root.path.length + 1);

  Future<JsonMap> refOf(File f) async => {
    'path': relative(f),
    'name': f.uri.pathSegments.last,
    'mimeType': mimeFromName(f.path),
    'size': await f.length(),
  };

  /// Saves [bytes] as [name] in [folder], adding " (2)" etc. instead of overwriting.
  Future<JsonMap> save(List<int> bytes, String name, {String folder = 'downloads'}) async {
    final clean = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
    final safe = clean.isEmpty ? 'file' : clean;
    final dir = Directory('${root.path}/$folder');
    await dir.create(recursive: true);
    final dot = safe.lastIndexOf('.');
    final base = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    var file = File('${dir.path}/$safe');
    for (var n = 2; await file.exists(); n++) {
      file = File('${dir.path}/$base ($n)$ext');
    }
    await file.writeAsBytes(bytes);
    return refOf(file);
  }
}

/// The file name a download should get: from Content-Disposition, else the URL, else a type-based name.
String downloadName(Uri url, Map<String, String> headers) {
  final cd = headers['content-disposition'] ?? '';
  final m = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''', caseSensitive: false).firstMatch(cd);
  if (m != null) return Uri.decodeComponent(m[1]!.trim());
  final last = url.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  if (last != null && last.contains('.')) return Uri.decodeComponent(last);
  final type = (headers['content-type'] ?? '').split(';').first.trim();
  final ext = _types.entries.where((e) => e.value == type).map((e) => e.key).firstOrNull ?? 'bin';
  return 'download.$ext';
}
