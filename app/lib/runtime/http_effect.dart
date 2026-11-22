import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../core/json.dart';
import 'credential_resolver.dart';
import 'file_store.dart';

/// Sends the requests of an `http` effect, one per item, in order.
/// Requests that name a credential get its secrets filled in just before sending.
class HttpEffect {
  HttpEffect({http.Client? client, this.credentials, this.files}) : _client = client ?? http.Client();

  final http.Client _client;
  final CredentialResolver? credentials;

  /// FlowDroid's folder, for requests that send or save files; null when files aren't available.
  final FileStore? files;

  static final _marker = RegExp(r'@@flowdroid-file-base64:(.*?)@@');

  Future<JsonMap> call(JsonMap effect) async {
    final responses = <JsonMap>[];
    for (final request in asMapList(effect['requests'])) {
      responses.add(await _send(request));
    }
    return {'responses': responses};
  }

  Future<JsonMap> _send(JsonMap raw) async {
    var secrets = const <String>[];
    try {
      final JsonMap spec;
      final resolver = credentials;
      if (resolver != null && raw['credential'] is String) {
        (spec, secrets) = await resolver.resolve(raw);
      } else {
        spec = raw;
      }
      final uri = Uri.tryParse(asString(spec['url']));
      if (uri == null || !uri.hasScheme) return {'error': 'invalid URL'};
      final request = await _build(spec, uri);
      final timeout = Duration(milliseconds: asInt(spec['timeoutMs'], 30000));
      final response = await http.Response.fromStream(await _client.send(request).timeout(timeout)).timeout(timeout);
      if (spec['saveAs'] == 'file' && response.statusCode < 400) {
        final ref = await _store.save(response.bodyBytes, downloadName(uri, response.headers));
        return {'status': response.statusCode, 'headers': response.headers, 'body': jsonEncode(ref)};
      }
      return {'status': response.statusCode, 'headers': response.headers, 'body': response.body};
    } on FileStoreException catch (e) {
      return {'error': e.message};
    } on Exception catch (e) {
      // Error texts can include the URL, which may carry a token (Telegram); never show secrets.
      return {'error': scrub(e.toString(), secrets)};
    }
  }

  FileStore get _store {
    final store = files;
    if (store == null) throw const FileStoreException('files are not available here');
    return store;
  }

  /// The request: plain, a file as the body, a multipart form, or Drive's multipart/related.
  Future<http.BaseRequest> _build(JsonMap spec, Uri uri) async {
    final method = asString(spec['method'], 'GET');
    final headers = asMap(spec['headers']).map((k, v) => MapEntry(k, asString(v)));
    final multipart = asMapList(spec['multipart']);
    if (multipart.isNotEmpty) {
      final form = http.MultipartRequest(method, uri);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'content-type') form.headers[k] = v;
      });
      for (final part in multipart) {
        final name = asString(part['name']);
        if (part['file'] is String) {
          final f = await _store.existing(part['file']! as String);
          form.files.add(
            await http.MultipartFile.fromPath(name, f.path, contentType: MediaType.parse(mimeFromName(f.path))),
          );
        } else {
          form.fields[name] = asString(part['value']);
        }
      }
      return form;
    }
    final request = http.Request(method, uri);
    headers.forEach((k, v) => request.headers[k] = v);
    final related = asMap(spec['related']);
    if (related.isNotEmpty) {
      const boundary = 'flowdroid-related-part';
      final f = await _store.existing(asString(related['file']));
      request.headers['Content-Type'] = 'multipart/related; boundary=$boundary';
      request.bodyBytes = [
        ...utf8.encode(
          '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(related['metadata'])}\r\n--$boundary\r\n'
          'Content-Type: ${asString(related['mimeType'], mimeFromName(f.path))}\r\n\r\n',
        ),
        ...await f.readAsBytes(),
        ...utf8.encode('\r\n--$boundary--'),
      ];
      return request;
    }
    if (spec['file'] is String) {
      request.bodyBytes = await (await _store.existing(spec['file']! as String)).readAsBytes();
      return request;
    }
    var body = spec['body'];
    if (body is String && spec['inlineFiles'] == true) {
      // Images for AI models: the file's bytes, base64-encoded, where the marker is.
      final parts = <String>[];
      var at = 0;
      for (final m in _marker.allMatches(body)) {
        parts
          ..add(body.substring(at, m.start))
          ..add(base64.encode(await (await _store.existing(m[1]!)).readAsBytes()));
        at = m.end;
      }
      parts.add(body.substring(at));
      body = parts.join();
    }
    if (body is String) request.body = body;
    return request;
  }
}
