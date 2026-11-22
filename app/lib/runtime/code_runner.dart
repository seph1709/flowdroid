import 'dart:convert';
import 'dart:io';

import '../core/json.dart';
import '../core/workflow.dart';
import 'linux/apt_progress.dart';
import 'linux/linux_runtime.dart';

/// Runs the Code node's JavaScript (Node.js) or Python inside FlowDroid's
/// Ubuntu. The language is installed with apt the first time it is needed.
class CodeRunner {
  CodeRunner(this.linux);

  final LinuxRuntime linux;

  static const _installTimeout = Duration(minutes: 15);

  static const _python = r'''
import json, sys
with open(sys.argv[1]) as f:
    __data = json.load(f)
items = __data["items"]

def __user(items, item, index):
__CODE__

if __data["mode"] == "allItems":
    __out = __user(items, None, None)
else:
    __out = [__user(items, it, i) for i, it in enumerate(items)]
with open(sys.argv[2], "w") as f:
    json.dump(__out, f, default=str)
''';

  static const _javascript = r'''
const fs = require('fs');
const __data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const items = __data.items;
async function __user(items, item, index) {
__CODE__
}
(async () => {
  let out;
  if (__data.mode === 'allItems') {
    out = await __user(items, undefined, undefined);
  } else {
    out = [];
    for (let i = 0; i < items.length; i++) out.push(await __user(items, items[i], i));
  }
  const clean = (v) => (v === undefined ? null : v);
  fs.writeFileSync(process.argv[3], JSON.stringify(Array.isArray(out) && __data.mode !== 'allItems' ? out.map(clean) : clean(out)));
})().catch((e) => {
  console.error((e && e.stack) || String(e));
  process.exit(1);
});
''';

  Future<JsonMap> call(JsonMap effect) async {
    final python = asString(effect['language']) == 'python';
    final code = asString(effect['code']);
    final ready = await _ensureInstalled(python);
    if (ready != null) return {'error': ready};

    final id = newId('code_');
    final dir = Directory('${linux.rootfs.path}/tmp/$id');
    await dir.create(recursive: true);
    try {
      final script = python
          ? _python.replaceFirst('__CODE__', _indent(code.isEmpty ? 'return None' : code))
          : _javascript.replaceFirst('__CODE__', code);
      await File('${dir.path}/main.${python ? 'py' : 'js'}').writeAsString(script);
      await File(
        '${dir.path}/in.json',
      ).writeAsString(jsonEncode({'mode': asString(effect['mode'], 'allItems'), 'items': effect['items'] ?? const []}));
      final inside = '/tmp/$id';
      final command = python
          ? 'python3 $inside/main.py $inside/in.json $inside/out.json'
          : 'node $inside/main.js $inside/in.json $inside/out.json';
      final r = await linux.run(
        command,
        target: LinuxTarget.ubuntu,
        timeout: Duration(milliseconds: asInt(effect['timeoutMs'], 60000)),
      );
      if (r.error != null) return {'error': r.error};
      if (r.exitCode != 0) return {'error': _lastLines(r.stderr.isEmpty ? r.stdout : r.stderr)};
      final out = File('${dir.path}/out.json');
      if (!await out.exists()) return {'error': 'the code produced no result'};
      return {'results': jsonDecode(await out.readAsString())};
    } finally {
      await dir.delete(recursive: true).catchError((Object _) => dir);
    }
  }

  /// Installs Python or Node.js on first use; null when ready, else what went wrong.
  Future<String?> _ensureInstalled(bool python) async {
    if (!await linux.ubuntuInstalled) {
      return 'the Code node runs in FlowDroid’s Ubuntu: install it in Settings → Terminal';
    }
    final binary = python ? 'python3' : 'node';
    final package = python ? 'python3-minimal' : 'nodejs';
    final check = await linux.run('command -v $binary', target: LinuxTarget.ubuntu);
    if (check.error == null && check.exitCode == 0) return null;
    final title = python ? 'Installing Python' : 'Installing Node.js';
    final progress = AptProgress();
    linux.activity.value = LinuxActivity(title, 'Updating package lists');
    final CommandOutput r;
    try {
      r = await linux.run(
        'apt-get update -qq >/dev/null && apt-get install -y -qq -o APT::Status-Fd=1 $package',
        target: LinuxTarget.ubuntu,
        timeout: _installTimeout,
        onOutput: (text, {required isError}) {
          if (isError) return;
          final p = progress.feedChunk(text);
          if (p != null) linux.activity.value = LinuxActivity(title, p.step, p.fraction);
        },
      );
    } finally {
      linux.activity.value = null;
    }
    if (r.error != null) return r.error;
    if (r.exitCode != 0) return 'could not install $package: ${_lastLines(r.stderr)}';
    return null;
  }

  static String _indent(String code) => code.split('\n').map((line) => '    $line').join('\n');

  /// The end of an error output, where the actual message is.
  static String _lastLines(String text) {
    final lines = text.trimRight().split('\n');
    return lines.sublist(lines.length > 6 ? lines.length - 6 : 0).join('\n');
  }
}
