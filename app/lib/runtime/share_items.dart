import 'dart:convert';

import '../core/json.dart';
import 'file_store.dart';

/// Text files bigger than this are passed by reference only.
const maxInlineText = 2 * 1024 * 1024;

/// The Share Trigger's items: one per shared file (with its reference, and its
/// text for text-type files), or a single item when only text was shared.
Future<List<JsonMap>> shareItems(
  FileStore store, {
  String? text,
  String? subject,
  List<String> files = const [],
}) async {
  final shared = text ?? '';
  final url = RegExp(r'https?://\S+').firstMatch(shared)?[0];
  JsonMap base() => {'text': shared, 'subject': subject, 'url': url, 'files': files};
  if (files.isEmpty) return [base()];
  final items = <JsonMap>[];
  for (final path in files) {
    final item = base();
    try {
      final f = await store.existing(path);
      final ref = await store.refOf(f);
      item['file'] = ref;
      if (isTextMime(asString(ref['mimeType'])) && asInt(ref['size']) <= maxInlineText) {
        final content = utf8.decode(await f.readAsBytes(), allowMalformed: true).replaceFirst('﻿', '');
        item['fileText'] = content;
        // Shared only a file: its text is the text, so the usual {{ $json.text }} works.
        if (shared.trim().isEmpty) item['text'] = content;
      }
    } on FileStoreException {
      item['file'] = null;
    }
    items.add(item);
  }
  return items;
}
