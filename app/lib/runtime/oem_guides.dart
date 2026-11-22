/// What each phone maker's own battery manager needs before FlowDroid can run
/// in the background. Steps follow dontkillmyapp.com; menu names vary a little
/// between system versions.
class OemGuide {
  const OemGuide({required this.name, required this.steps, this.autostartLabel, this.lockInRecents = true});

  /// Shown as "On your Huawei".
  final String name;

  /// Short, numbered steps in the maker's own words.
  final List<String> steps;

  /// The button that opens the maker's launch manager; null when there is none.
  final String? autostartLabel;

  /// The maker's "clear all" in recent apps also stops FlowDroid unless it is locked.
  final bool lockInRecents;

  /// Phones that need nothing beyond Android's own battery setting.
  bool get isStock => steps.isEmpty;
}

const _huawei = OemGuide(
  name: 'Huawei',
  autostartLabel: 'Open App launch',
  steps: [
    'Settings → Battery → App launch → FlowDroid',
    'Turn off “Manage automatically”',
    'Turn on Auto-launch, Secondary launch and Run in background, then tap OK',
  ],
);

const _honor = OemGuide(
  name: 'Honor',
  autostartLabel: 'Open App launch',
  steps: [
    'Settings → Battery → App launch → FlowDroid',
    'Turn off “Manage automatically”',
    'Turn on Auto-launch, Secondary launch and Run in background',
  ],
);

const _xiaomi = OemGuide(
  name: 'Xiaomi',
  autostartLabel: 'Open Autostart',
  steps: [
    'Security → Permissions → Autostart: turn on FlowDroid',
    'Settings → Apps → FlowDroid → Battery saver: choose “No restrictions”',
  ],
);

const _oppo = OemGuide(
  name: 'Oppo / Realme',
  autostartLabel: 'Open Auto launch',
  steps: [
    'Settings → Apps → Auto launch: turn on FlowDroid',
    'Settings → Apps → FlowDroid → Battery usage: allow background activity',
  ],
);

const _oneplus = OemGuide(
  name: 'OnePlus',
  autostartLabel: 'Open Auto launch',
  steps: [
    'Settings → Apps → Auto launch: turn on FlowDroid',
    'Settings → Battery → Battery optimization → FlowDroid: “Don’t optimize”',
  ],
);

const _vivo = OemGuide(
  name: 'Vivo / iQOO',
  autostartLabel: 'Open Background manager',
  steps: [
    'i Manager → App manager → Autostart: turn on FlowDroid',
    'Settings → Battery → Background power consumption: allow FlowDroid',
  ],
);

const _samsung = OemGuide(
  name: 'Samsung',
  autostartLabel: 'Open Battery',
  lockInRecents: false,
  steps: [
    'Settings → Battery → Background usage limits: add FlowDroid to “Never sleeping apps”',
    'Turn off “Put unused apps to sleep”',
  ],
);

const _transsion = OemGuide(
  name: 'Tecno / Infinix / itel',
  autostartLabel: 'Open Auto-start',
  steps: [
    'Phone Master → App management → Auto-start: turn on FlowDroid',
    'Settings → Battery → FlowDroid: turn off power saving for it',
  ],
);

const _asus = OemGuide(
  name: 'Asus',
  autostartLabel: 'Open Auto-start',
  steps: ['Mobile Manager → Auto-start manager: allow FlowDroid'],
);

const _meizu = OemGuide(
  name: 'Meizu',
  autostartLabel: 'Open Background manager',
  steps: ['Security → Background management: allow FlowDroid to run in the background'],
);

const _stock = OemGuide(name: 'this phone', steps: [], lockInRecents: false);

/// The guide for a phone [maker] (lower-case, as Android reports it).
OemGuide guideFor(String maker) => switch (maker.toLowerCase()) {
  'huawei' => _huawei,
  'honor' => _honor,
  'xiaomi' || 'redmi' || 'poco' => _xiaomi,
  'oppo' || 'realme' => _oppo,
  'oneplus' => _oneplus,
  'vivo' || 'iqoo' => _vivo,
  'samsung' => _samsung,
  'tecno' || 'infinix' || 'itel' => _transsion,
  'asus' => _asus,
  'meizu' => _meizu,
  _ => _stock,
};

// ---------------------------------------------------------------- live guides

/// One piece of a live guide.
sealed class GuideBlock {
  const GuideBlock();
}

class GuideText extends GuideBlock {
  const GuideText(this.text, {this.bullet = false, this.code = false});

  final String text;
  final bool bullet;

  /// A command (shown monospaced), e.g. an adb line.
  final bool code;
}

/// Screenshots with their captions, in order.
class GuidePictures extends GuideBlock {
  const GuidePictures(this.pictures);

  final List<({String url, String caption})> pictures;
}

/// A titled part of a guide ("App launch", "Startup manager", …).
class GuideSection {
  GuideSection(this.title);

  final String title;
  final blocks = <GuideBlock>[];
}

/// The community guide for one phone maker, from dontkillmyapp.com.
class LiveGuide {
  const LiveGuide({required this.name, required this.severity, required this.sections, required this.fetchedAt});

  final String name;

  /// How hard the maker stops background apps, 0 (not at all) to 5.
  final int severity;
  final List<GuideSection> sections;
  final DateTime fetchedAt;
}

final _block = RegExp(
  r'<h[2-4][^>]*>([\s\S]*?)</h[2-4]>'
  r'|<li[^>]*>([\s\S]*?)</li>'
  r'|<p[^>]*>([\s\S]*?)</p>'
  r'|<pre[^>]*>([\s\S]*?)</pre>'
  r'|<figure[^>]*>([\s\S]*?)</figure>',
);

/// Plain text from a bit of HTML: tags dropped, entities decoded, spaces tidied.
String htmlText(String html) {
  var t = html
      .replaceAll(RegExp(r'<br\s*/?>'), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&gt;', '>')
      .replaceAll('&lt;', '<')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
  // Captions use Markdown emphasis.
  t = t.replaceAllMapped(RegExp(r'\*([^*\n]+)\*'), (m) => m[1]!);
  return t.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\s*\n\s*'), '\n').trim();
}

/// The `user_solution` HTML as sections of text, steps, commands and screenshots.
List<GuideSection> parseGuideHtml(String html) {
  final sections = <GuideSection>[GuideSection('')];
  for (final m in _block.allMatches(html)) {
    final current = sections.last;
    if (m[1] != null) {
      final title = htmlText(m[1]!);
      if (title.isNotEmpty) sections.add(GuideSection(title));
    } else if (m[2] != null || m[3] != null) {
      final text = htmlText(m[2] ?? m[3]!);
      if (text.isNotEmpty) current.blocks.add(GuideText(text, bullet: m[2] != null));
    } else if (m[4] != null) {
      final text = htmlText(m[4]!);
      if (text.isNotEmpty) current.blocks.add(GuideText(text, code: true));
    } else {
      final img = RegExp(r'<img[^>]*src="([^"]+)"').firstMatch(m[5]!)?[1];
      if (img == null) continue;
      final caption = htmlText(RegExp(r'<figcaption>([\s\S]*?)</figcaption>').firstMatch(m[5]!)?[1] ?? '');
      final picture = (url: img.startsWith('/') ? 'https://dontkillmyapp.com$img' : img, caption: caption);
      // Consecutive screenshots form one row.
      if (current.blocks.lastOrNull case GuidePictures(:final pictures)) {
        pictures.add(picture);
      } else {
        current.blocks.add(GuidePictures([picture]));
      }
    }
  }
  return sections.where((s) => s.blocks.isNotEmpty).toList();
}

/// dontkillmyapp.com's API path for a maker as Android names it.
String guideSlug(String maker) => switch (maker.toLowerCase()) {
  'redmi' || 'poco' => 'xiaomi',
  'iqoo' => 'vivo',
  'google' => 'google',
  final m => m.replaceAll(RegExp('[^a-z0-9-]'), ''),
};

LiveGuide? liveGuideFromJson(Map<String, Object?> json, DateTime fetchedAt) {
  final html = json['user_solution'];
  if (html is! String) return null;
  return LiveGuide(
    name: json['name'] as String? ?? '',
    severity: (json['award'] as num?)?.toInt() ?? 0,
    sections: parseGuideHtml(html),
    fetchedAt: fetchedAt,
  );
}
