import 'dart:io';

import '../core/json.dart';
import '../data/json_file_store.dart';

/// The "Phone Table" node's storage: one JSON document per table, rows matched by equality.
class TableEffect {
  TableEffect(Directory root) : _store = JsonFileStore(Directory('${root.path}/tables'));

  final JsonFileStore _store;

  static final _safeName = RegExp(r'[^A-Za-z0-9_-]');

  Future<JsonMap> call(JsonMap effect) async {
    final table = asString(effect['table']).replaceAll(_safeName, '_');
    if (table.isEmpty) return {'error': 'table name is empty'};
    final operation = asString(effect['operation']);
    final rows = asMapList((await _store.read(table))?['rows']);
    final out = <JsonMap>[];
    var changed = false;
    for (final request in asMapList(effect['requests'])) {
      final where = asMap(request['where']);
      final row = asMap(request['row']);
      bool matches(JsonMap r) => where.entries.every((w) => _text(r[w.key]) == _text(w.value));
      switch (operation) {
        case 'insert':
          final inserted = {...row, '_created': DateTime.now().toUtc().toIso8601String()};
          rows.add(inserted);
          out.add(inserted);
          changed = true;
        case 'find':
          out.addAll(rows.where(matches).take(asInt(request['limit'], 100)));
        case 'update':
          for (var i = 0; i < rows.length; i++) {
            if (!matches(rows[i])) continue;
            rows[i] = {...rows[i], ...row};
            out.add(rows[i]);
            changed = true;
          }
        case 'delete':
          final gone = rows.where(matches).toList();
          rows.removeWhere(matches);
          out.addAll(gone);
          changed = changed || gone.isNotEmpty;
        default:
          return {'error': 'unknown operation $operation'};
      }
    }
    if (changed) await _store.write(table, {'rows': rows});
    return {'rows': out};
  }

  /// Values compare as text, so a filter typed as "5" matches the number 5.
  static String _text(Object? v) => v == null ? '' : (v is String ? v : v.toString());
}
