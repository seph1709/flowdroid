import 'package:phone_bridge/phone_bridge.dart';

import '../../core/json.dart';
import 'browser_driver.dart';

/// [BrowserPage] backed by the phone's in-app browser.
class PhoneBrowser implements BrowserPage {
  PhoneBrowser(this.phone);

  final PhoneBridge phone;

  @override
  Future<JsonMap> open(String session, String url, {required bool fast, required int timeoutMs}) async =>
      asMap(await phone.browserOpen(session, url, fast: fast, timeoutMs: timeoutMs));

  @override
  Future<String?> eval(String session, String js) => phone.browserEval(session, js);

  @override
  Future<bool> back(String session) => phone.browserBack(session);

  @override
  Future<JsonMap> screenshot(String session, String path) async => asMap(await phone.browserScreenshot(session, path));

  @override
  Future<JsonMap> show(String session) async => asMap(await phone.browserShow(session));

  @override
  Future<void> hide(String session) => phone.browserHide(session);
}
