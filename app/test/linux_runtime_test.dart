import 'dart:io';

import 'package:flowdroid/runtime/linux/linux_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LinuxRuntime linux;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('flowdroid_linux');
    linux = LinuxRuntime(dir, shell: '/bin/sh', libraryDir: '/nonexistent');
  });

  test('phone commands return their output and exit code, streaming as they print', () async {
    final seen = <String>[];
    final r = await linux.run(
      'echo out; echo err >&2; exit 3',
      onOutput: (text, {required isError}) => seen.add('${isError ? 'E' : 'O'}:$text'),
    );
    expect(r.error, isNull);
    expect(r.stdout, 'out\n');
    expect(r.stderr, 'err\n');
    expect(r.exitCode, 3);
    expect(seen, containsAll(['O:out\n', 'E:err\n']));
  });

  test('a command that runs too long is stopped', () async {
    final r = await linux.run('sleep 5', timeout: const Duration(milliseconds: 200));
    expect(r.error, 'the command did not finish within 0 s');
  });

  test('Ubuntu commands explain how to install Ubuntu first', () async {
    expect(await linux.ubuntuInstalled, isFalse);
    final r = await linux.run('uname', target: LinuxTarget.ubuntu);
    expect(r.error, contains('Ubuntu is not installed yet'));
  });
}
