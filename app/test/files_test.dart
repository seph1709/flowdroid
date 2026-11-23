import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flowdroid/runtime/file_store.dart';
import 'package:flowdroid/runtime/http_effect.dart';
import 'package:flowdroid/runtime/share_items.dart';
import 'package:flowdroid/runtime/text_extractor.dart';
import 'package:flowdroid/ui/widgets/file_cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory data;
  late FileStore store;
  setUp(() async {
    data = await Directory.systemTemp.createTemp('files');
    store = FileStore(data);
    await Directory('${store.root.path}/shared').create(recursive: true);
  });

  test('paths stay inside FlowDroid’s folder; saving never overwrites', () async {
    expect(store.resolve('shared/a.txt').path, '${store.root.path}/shared/a.txt');
    expect(store.resolve('/root/files/shared/a.txt').path, '${store.root.path}/shared/a.txt');
    expect(() => store.resolve('../secrets'), throwsA(isA<FileStoreException>()));
    final a = await store.save([1, 2, 3], 'report.pdf');
    final b = await store.save([4], 'report.pdf');
    expect(a, {'path': 'downloads/report.pdf', 'name': 'report.pdf', 'mimeType': 'application/pdf', 'size': 3});
    expect(b['path'], 'downloads/report (2).pdf');
    expect(
      downloadName(Uri.parse('https://x.io/get?id=1'), {'content-disposition': 'attachment; filename="Q3 plan.docx"'}),
      'Q3 plan.docx',
    );
    expect(downloadName(Uri.parse('https://x.io/img/cat.png'), {}), 'cat.png');
    expect(downloadName(Uri.parse('https://x.io/'), {'content-type': 'image/jpeg'}), 'download.jpg');
  });

  test('HTTP: file body, multipart, Drive related upload, image inlining, saving downloads', () async {
    await File('${store.root.path}/shared/cat.png').writeAsBytes([137, 80, 78, 71]);
    final seen = <http.BaseRequest>[];
    final bodies = <List<int>>[];
    final client = MockClient.streaming((req, stream) async {
      seen.add(req);
      bodies.add(await stream.toBytes());
      return http.StreamedResponse(
        Stream.value([9, 9]),
        200,
        headers: {'content-type': 'image/png', 'content-disposition': 'attachment; filename=out.png'},
      );
    });
    final effect = HttpEffect(client: client, files: store);
    final r = await effect.call({
      'requests': [
        {
          'method': 'PUT',
          'url': 'https://x.io/a',
          'headers': <String, String>{},
          'file': 'shared/cat.png',
          'saveAs': 'file',
        },
        {
          'method': 'POST',
          'url': 'https://x.io/b',
          'headers': <String, String>{},
          'multipart': [
            {'name': 'chat_id', 'value': '42'},
            {'name': 'photo', 'file': 'shared/cat.png'},
          ],
        },
        {
          'method': 'POST',
          'url': 'https://x.io/c',
          'headers': <String, String>{},
          'related': {
            'metadata': {'name': 'cat.png'},
            'file': 'shared/cat.png',
            'mimeType': 'image/png',
          },
        },
        {
          'method': 'POST',
          'url': 'https://x.io/d',
          'headers': <String, String>{},
          'inlineFiles': true,
          'body': '{"data":"@@flowdroid-file-base64:shared/cat.png@@"}',
        },
      ],
    });
    final responses = (r['responses']! as List).cast<Map<String, Object?>>();
    expect(bodies[0], [137, 80, 78, 71]);
    expect(jsonDecode(responses[0]['body']! as String), containsPair('path', 'downloads/out.png'));
    expect(seen[1].headers['content-type'], startsWith('multipart/form-data'));
    expect(
      utf8.decode(bodies[1], allowMalformed: true),
      allOf(contains('name="chat_id"'), contains('filename="cat.png"')),
    );
    expect(seen[2].headers['Content-Type'], 'multipart/related; boundary=flowdroid-related-part');
    expect(utf8.decode(bodies[2], allowMalformed: true), contains('{"name":"cat.png"}'));
    expect(utf8.decode(bodies[3]), '{"data":"${base64.encode([137, 80, 78, 71])}"}');

    final missing = await effect.call({
      'requests': [
        {'method': 'PUT', 'url': 'https://x.io/a', 'headers': <String, String>{}, 'file': 'shared/nope.png'},
      ],
    });
    expect(((missing['responses']! as List).single as Map)['error'], 'file not found: shared/nope.png');
  });

  test('Extract Text: plain, HTML, Word; images explain why not', () async {
    final x = TextExtractor(files: store);
    await File('${store.root.path}/shared/n.md').writeAsString('﻿# Notes\nHello');
    await File('${store.root.path}/shared/p.html').writeAsString(
      '<html><style>b{}</style><body><h1>Title</h1><p>One &amp; two</p><script>x()</script></body></html>',
    );
    final doc = Archive()
      ..addFile(
        ArchiveFile.string(
          'word/document.xml',
          '<w:document><w:body><w:p><w:r><w:t>First</w:t></w:r></w:p><w:p><w:r><w:t>Second &amp; last</w:t></w:r></w:p></w:body></w:document>',
        ),
      );
    await File('${store.root.path}/shared/d.docx').writeAsBytes(ZipEncoder().encode(doc));
    await File('${store.root.path}/shared/photo.jpg').writeAsBytes([1]);
    final r = await x.call({
      'files': ['shared/n.md', 'shared/p.html', 'shared/d.docx', 'shared/photo.jpg', 'shared/none.txt'],
    });
    final results = (r['results']! as List).cast<Map<String, Object?>>();
    expect(results[0], {'text': '# Notes\nHello'});
    expect(results[1], {'text': 'Title\nOne & two'});
    expect(results[2], {'text': 'First\nSecond & last'});
    expect(results[3]['error'], 'photo.jpg is an image: there is no text in it to extract');
    expect(results[4]['error'], 'file not found: shared/none.txt');
    final pdf = await x.call({
      'files': ['shared/d.docx'.replaceAll('docx', 'pdf')],
    });
    expect(((pdf['results']! as List).single as Map)['error'], contains('not found'));
  });

  test('Share: one item per file, text files read in', () async {
    await File('${store.root.path}/shared/1-notes.txt').writeAsString('Buy milk');
    await File('${store.root.path}/shared/2-cat.jpg').writeAsBytes([1, 2]);
    final items = await shareItems(store, subject: 'From Files', files: ['shared/1-notes.txt', 'shared/2-cat.jpg']);
    expect(items, hasLength(2));
    expect(items[0]['text'], 'Buy milk');
    expect(items[0]['fileText'], 'Buy milk');
    expect((items[0]['file']! as Map)['name'], '1-notes.txt');
    expect(items[1]['text'], '');
    expect(items[1].containsKey('fileText'), isFalse);
    expect((items[1]['file']! as Map)['mimeType'], 'image/jpeg');
    expect(await shareItems(store, text: 'see https://a.io/x ok'), [
      {'text': 'see https://a.io/x ok', 'subject': null, 'url': 'https://a.io/x', 'files': <String>[]},
    ]);
    expect(fileRefsIn(items), hasLength(2));
  });
}
