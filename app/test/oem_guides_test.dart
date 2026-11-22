import 'dart:convert';
import 'dart:io';

import 'package:flowdroid/runtime/oem_guide_source.dart';
import 'package:flowdroid/runtime/oem_guides.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _html = '''
<h3 id="a">Smart Tune-up</h3>
<p>There is a pre-installed app &amp; it kills apps.</p>
<div class="img-block">
  <figure><img src="https://dontkillmyapp.com/assets/img/huawei/1.jpg" /><figcaption>1. Open the *System Manager*.</figcaption></figure>
  <figure><img src="/assets/img/huawei/2.jpg" /><figcaption>2. Disable it.</figcaption></figure>
</div>
<h3 id="b">App Launch</h3>
<ul>
  <li><em>Phone settings &gt; Battery &gt; App launch</em> and set “Manage manually”.</li>
</ul>
<pre><code>adb shell pm uninstall --user 0 com.huawei.powergenie</code></pre>
''';

void main() {
  test('the site’s HTML becomes sections of text, steps, commands and screenshots', () {
    final sections = parseGuideHtml(_html);
    expect(sections.map((s) => s.title), ['Smart Tune-up', 'App Launch']);
    final first = sections.first.blocks;
    expect((first[0] as GuideText).text, 'There is a pre-installed app & it kills apps.');
    final pics = (first[1] as GuidePictures).pictures;
    expect(pics.map((p) => p.caption), ['1. Open the System Manager.', '2. Disable it.']);
    expect(pics.last.url, 'https://dontkillmyapp.com/assets/img/huawei/2.jpg');
    final step = sections.last.blocks.first as GuideText;
    expect(step.bullet, isTrue);
    expect(step.text, 'Phone settings > Battery > App launch and set “Manage manually”.');
    expect((sections.last.blocks.last as GuideText).code, isTrue);
  });

  test('makers map to the site’s pages', () {
    expect(guideSlug('HUAWEI'), 'huawei');
    expect(guideSlug('Redmi'), 'xiaomi');
    expect(guideSlug('iqoo'), 'vivo');
    expect(guideSlug('Sony Mobile'), 'sonymobile');
  });

  test('loads, keeps a copy, and falls back to it offline', () async {
    final dir = await Directory.systemTemp.createTemp('guides');
    var now = DateTime(2026, 11, 22);
    var online = true;
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      if (!online) throw const SocketException('offline');
      if (r.url.path.endsWith('/google.json')) return http.Response('not found', 404);
      return http.Response.bytes(utf8.encode(jsonEncode({'name': 'Huawei', 'award': 5, 'user_solution': _html})), 200);
    });
    final source = OemGuideSource(dir, client: client, clock: () => now);

    final guide = await source.load('huawei');
    expect(guide!.name, 'Huawei');
    expect(guide.severity, 5);
    expect(guide.sections, hasLength(2));

    await source.load('huawei');
    expect(calls, 1, reason: 'fresh copy is reused for a week');

    now = now.add(const Duration(days: 8));
    online = false;
    expect((await source.load('huawei'))?.name, 'Huawei', reason: 'offline: the saved copy');

    online = true;
    expect(await source.load('google'), isNull, reason: 'no page: stock Android');
  });
}
