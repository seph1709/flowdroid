import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../core/json.dart';

/// Reads RSS 2.0 and Atom feeds into one item per post.
class FeedReader {
  FeedReader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The `rss` effect: one list of posts per URL.
  Future<JsonMap> call(JsonMap effect) async {
    final feeds = <List<JsonMap>>[];
    for (final url in asList(effect['urls'])) {
      feeds.add(await read(asString(url)));
    }
    return {'feeds': feeds};
  }

  Future<List<JsonMap>> read(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) throw FeedException('“$url” is not a URL');
    final response = await _client.get(uri, headers: {'User-Agent': 'FlowDroid'}).timeout(const Duration(seconds: 30));
    if (response.statusCode >= 400) throw FeedException('the feed answered HTTP ${response.statusCode}');
    return parse(response.body);
  }

  /// Posts in [xml], newest first as the feed lists them.
  static List<JsonMap> parse(String xml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException {
      throw const FeedException('the page is not an RSS or Atom feed');
    }
    String text(XmlElement e, String name) => e.findElements(name).firstOrNull?.innerText.trim() ?? '';
    final rssItems = doc.findAllElements('item');
    if (rssItems.isNotEmpty) {
      return [
        for (final item in rssItems)
          {
            'title': text(item, 'title'),
            'link': text(item, 'link'),
            'id': text(item, 'guid').isNotEmpty ? text(item, 'guid') : text(item, 'link'),
            'published': text(item, 'pubDate'),
            'author': text(item, 'author').isNotEmpty ? text(item, 'author') : text(item, 'dc:creator'),
            'summary': text(item, 'description'),
          },
      ];
    }
    return [
      for (final entry in doc.findAllElements('entry'))
        {
          'title': text(entry, 'title'),
          'link': _atomLink(entry),
          'id': text(entry, 'id').isNotEmpty ? text(entry, 'id') : _atomLink(entry),
          'published': text(entry, 'published').isNotEmpty ? text(entry, 'published') : text(entry, 'updated'),
          'author': entry.findElements('author').firstOrNull?.findElements('name').firstOrNull?.innerText.trim() ?? '',
          'summary': text(entry, 'summary').isNotEmpty ? text(entry, 'summary') : text(entry, 'content'),
        },
    ];
  }

  static String _atomLink(XmlElement entry) {
    final links = entry.findElements('link').toList();
    final alternate = links.where((l) => (l.getAttribute('rel') ?? 'alternate') == 'alternate').firstOrNull;
    return (alternate ?? links.firstOrNull)?.getAttribute('href') ?? '';
  }
}

class FeedException implements Exception {
  const FeedException(this.message);

  final String message;

  @override
  String toString() => message;
}
