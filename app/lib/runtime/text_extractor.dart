import 'dart:convert';

import 'package:archive/archive.dart';

import '../core/json.dart';
import 'file_store.dart';
import 'linux/apt_progress.dart';
import 'linux/linux_runtime.dart';

/// Visible text of an HTML page: no scripts, styles or tags; blocks on their own lines.
String htmlToText(String html) {
  var t = html
      .replaceAll(RegExp(r'<(script|style|noscript)[\s\S]*?</\1>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|li|h[1-6]|tr|section|article)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  t = _entities(t);
  return t.split('\n').map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim()).where((l) => l.isNotEmpty).join('\n');
}

String _entities(String t) => t
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAll('&amp;', '&');

/// The text of a Word (.docx) file: paragraphs as lines.
String docxToText(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final doc = archive.findFile('word/document.xml');
  if (doc == null) throw const FileStoreException('this .docx has no document inside');
  final xml = utf8.decode(doc.content as List<int>, allowMalformed: true);
  final t = xml
      .replaceAll(RegExp(r'</w:p>'), '\n')
      .replaceAll(RegExp(r'<w:tab/>'), '\t')
      .replaceAll(RegExp(r'<w:br/>'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  return _entities(t).split('\n').map((l) => l.trimRight()).join('\n').trim();
}

/// The `extract` effect: the text out of each file, `{text}` or `{error}` per file.
class TextExtractor {
  TextExtractor({required this.files, this.linux});

  final FileStore files;
  final LinuxRuntime? linux;

  Future<JsonMap> call(JsonMap effect) async {
    final results = <JsonMap>[];
    for (final path in asList(effect['files']).whereType<String>()) {
      try {
        results.add({'text': await extract(path)});
      } on FileStoreException catch (e) {
        results.add({'error': e.message});
      }
    }
    return {'results': results};
  }

  Future<String> extract(String path) async {
    final f = await files.existing(path);
    final name = f.uri.pathSegments.last;
    final mime = mimeFromName(name);
    if (mime == 'text/html') return htmlToText(utf8.decode(await f.readAsBytes(), allowMalformed: true));
    if (isTextMime(mime)) {
      return utf8.decode(await f.readAsBytes(), allowMalformed: true).replaceFirst('﻿', '');
    }
    if (name.toLowerCase().endsWith('.docx')) return docxToText(await f.readAsBytes());
    if (mime == 'application/pdf') return _pdf(f.path, name);
    final kind = mime.split('/').first;
    throw FileStoreException(
      kind == 'image' || kind == 'audio' || kind == 'video'
          ? '$name is ${kind == 'image' ? 'an image' : kind}: there is no text in it to extract'
          : '$name ($mime) is not a kind of file Extract Text can read',
    );
  }

  /// PDFs: `pdftotext` in FlowDroid's Ubuntu, installed the first time it's needed.
  Future<String> _pdf(String hostPath, String name) async {
    final linux = this.linux;
    if (linux == null || !await linux.ubuntuInstalled) {
      throw const FileStoreException('PDFs are read with FlowDroid’s Ubuntu: install it in Settings → Terminal');
    }
    final check = await linux.run('command -v pdftotext', target: LinuxTarget.ubuntu);
    if (check.error != null || check.exitCode != 0) {
      final progress = AptProgress();
      linux.activity.value = const LinuxActivity('Installing the PDF reader', 'Updating package lists');
      try {
        final r = await linux.run(
          'apt-get update -qq >/dev/null && apt-get install -y -qq -o APT::Status-Fd=1 poppler-utils',
          target: LinuxTarget.ubuntu,
          timeout: const Duration(minutes: 15),
          onOutput: (text, {required isError}) {
            if (isError) return;
            final p = progress.feedChunk(text);
            if (p != null) linux.activity.value = LinuxActivity('Installing the PDF reader', p.step, p.fraction);
          },
        );
        if (r.error != null || r.exitCode != 0) {
          throw FileStoreException('could not install the PDF reader: ${r.error ?? r.stderr.trim().split('\n').last}');
        }
      } finally {
        linux.activity.value = null;
      }
    }
    final inside = '/root/files/${files.relative(files.resolve(hostPath))}';
    final quoted = "'${inside.replaceAll("'", r"'\''")}'";
    final r = await linux.run(
      'pdftotext -layout $quoted -',
      target: LinuxTarget.ubuntu,
      timeout: const Duration(minutes: 5),
    );
    if (r.error != null) throw FileStoreException(r.error!);
    if (r.exitCode != 0) throw FileStoreException('$name could not be read: ${r.stderr.trim().split('\n').last}');
    final text = r.stdout.trim();
    if (text.isEmpty) throw FileStoreException('$name has no text layer (a scan or photos of pages)');
    return text;
  }
}
