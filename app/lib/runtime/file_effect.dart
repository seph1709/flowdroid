import 'dart:io';

import '../core/json.dart';

/// The Files node's storage: FlowDroid's own folder (in Ubuntu: /root/files).
class FileEffect {
  FileEffect(this.root);

  final Directory root;

  Future<JsonMap> call(JsonMap effect) async {
    final results = <Object?>[];
    for (final request in asMapList(effect['requests'])) {
      final relative = asString(request['path']);
      final path = _resolve(relative);
      if (path == null) return {'error': 'path “$relative” must stay inside FlowDroid’s folder'};
      switch (asString(request['operation'])) {
        case 'read':
          final file = File(path);
          if (!await file.exists()) return {'error': 'file “$relative” does not exist'};
          results.add({'path': relative, 'content': await file.readAsString()});
        case 'write' || 'append':
          final file = File(path);
          await file.parent.create(recursive: true);
          final append = asString(request['operation']) == 'append';
          await file.writeAsString(asString(request['content']), mode: append ? FileMode.append : FileMode.write);
          results.add({'path': relative, 'size': await file.length()});
        case 'list':
          final dir = Directory(path);
          if (!await dir.exists()) {
            results.add(<JsonMap>[]);
            continue;
          }
          final entries = <JsonMap>[];
          await for (final e in dir.list()) {
            final stat = await e.stat();
            final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
            entries.add({
              'name': name,
              'path': relative.isEmpty ? name : '$relative/$name',
              'isFolder': stat.type == FileSystemEntityType.directory,
              'size': stat.size,
              'modified': stat.modified.toUtc().toIso8601String(),
            });
          }
          entries.sort((a, b) => asString(a['name']).compareTo(asString(b['name'])));
          results.add(entries);
        case 'delete':
          final entity = FileSystemEntity.typeSync(path) == FileSystemEntityType.directory
              ? Directory(path)
              : File(path);
          final existed = await entity.exists();
          if (existed) await entity.delete(recursive: true);
          results.add({'path': relative, 'deleted': existed});
        default:
          return {'error': 'unknown file operation'};
      }
    }
    return {'results': results};
  }

  /// The absolute path for [relative], or null if it would leave the folder.
  String? _resolve(String relative) {
    final parts = relative.split('/').where((p) => p.isNotEmpty && p != '.').toList();
    if (parts.contains('..') || relative.startsWith('/')) return null;
    return parts.isEmpty ? root.path : '${root.path}/${parts.join('/')}';
  }
}
