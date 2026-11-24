import 'dart:convert';
import 'dart:io';

import 'package:phone_bridge/phone_bridge.dart';

import '../../core/json.dart';

/// A site the person logged in to in FlowDroid's browser.
class SavedLogin {
  const SavedLogin({required this.site, required this.url, required this.at});

  SavedLogin.fromJson(JsonMap json)
    : site = asString(json['site']),
      url = asString(json['url']),
      at = DateTime.tryParse(asString(json['at'])) ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// The host, e.g. `github.com`.
  final String site;

  /// Where the login started.
  final String url;
  final DateTime at;

  JsonMap toJson() => {'site': site, 'url': url, 'at': at.toIso8601String()};
}

/// Logins kept in FlowDroid's browser. The browser itself keeps the cookies and
/// site storage (like any browser, on this phone only); this remembers which
/// sites they are for, so they can be listed, renewed and removed one by one.
class BrowserLogins {
  BrowserLogins(Directory dataDir, this.phone) : _file = File('${dataDir.path}/browser_logins.json');

  final PhoneBridge phone;
  final File _file;

  Future<List<SavedLogin>> list() async {
    try {
      return asMapList(jsonDecode(await _file.readAsString())).map(SavedLogin.fromJson).toList()
        ..sort((a, b) => b.at.compareTo(a.at));
    } on Object {
      return [];
    }
  }

  Future<void> _save(List<SavedLogin> all) => _file.writeAsString(jsonEncode(all.map((l) => l.toJson()).toList()));

  /// Shows [url] for the person to log in; `{url}` once they tap Done, or `{error}`.
  Future<JsonMap> logIn(String url) async {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    final host = Uri.tryParse(u)?.host ?? '';
    if (host.isEmpty) return {'error': 'not a web address: $url'};
    final r = asMap(await phone.browserLogin(u));
    if (r['error'] != null) return r;
    final all = (await list()).where((l) => l.site != host).toList()
      ..add(SavedLogin(site: host, url: u, at: DateTime.now()));
    await _save(all);
    return r;
  }

  /// Logs out of [site] only.
  Future<void> forget(SavedLogin login) async {
    await phone.browserForget(login.url);
    await _save((await list()).where((l) => l.site != login.site).toList());
  }

  /// Logs out of every site.
  Future<void> clearAll() async {
    await phone.browserClearLogins();
    await _save(const []);
  }
}
