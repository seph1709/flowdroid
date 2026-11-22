import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'oem_guides.dart';

/// Loads the live guide for this phone's maker from dontkillmyapp.com, keeping
/// a copy so it still shows offline. Only the maker's name is sent.
class OemGuideSource {
  OemGuideSource(Directory dataDir, {http.Client? client, DateTime Function()? clock})
    : _dir = Directory('${dataDir.path}/runtime/guides'),
      _client = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  static const refreshAfter = Duration(days: 7);

  final Directory _dir;
  final http.Client _client;
  final DateTime Function() _clock;

  /// The guide, or null when the site has none for [maker] (stock Android) and nothing is saved.
  Future<LiveGuide?> load(String maker, {bool refresh = false}) async {
    final slug = guideSlug(maker);
    if (slug.isEmpty) return null;
    final file = File('${_dir.path}/$slug.json');
    LiveGuide? saved;
    if (await file.exists()) {
      try {
        saved = liveGuideFromJson(asMap(jsonDecode(await file.readAsString())), await file.lastModified());
      } on FormatException {
        saved = null;
      }
    }
    if (saved != null && !refresh && _clock().difference(saved.fetchedAt) < refreshAfter) return saved;
    try {
      final r = await _client
          .get(Uri.parse('https://dontkillmyapp.com/api/v2/$slug.json'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) return saved;
      if (r.statusCode != 200) return saved;
      final guide = liveGuideFromJson(asMap(jsonDecode(utf8.decode(r.bodyBytes))), _clock());
      if (guide == null) return saved;
      await _dir.create(recursive: true);
      await file.writeAsBytes(r.bodyBytes);
      return guide;
    } on Object {
      return saved;
    }
  }
}
