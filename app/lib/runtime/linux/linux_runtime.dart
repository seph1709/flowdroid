import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Where a command runs: the phone's own shell, or the built-in Ubuntu.
enum LinuxTarget { phone, ubuntu }

/// What a command printed and how it ended; [error] is set when it could not run at all.
class CommandOutput {
  const CommandOutput({this.stdout = '', this.stderr = '', this.exitCode = 0, this.error});

  final String stdout;
  final String stderr;
  final int exitCode;
  final String? error;
}

/// How to start a shell: the program, its arguments and environment.
class ShellLaunch {
  const ShellLaunch({
    required this.executable,
    required this.arguments,
    required this.environment,
    this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;
}

/// One step of installing Ubuntu; [fraction] is null while the step's length is unknown.
class InstallProgress {
  const InstallProgress(this.step, [this.fraction, this.detail, this.stepNumber = 0]);

  final String step;
  final double? fraction;

  /// Bytes and speed while downloading.
  final String? detail;

  /// 1 to [steps]; 0 before it starts.
  final int stepNumber;

  static const steps = 4;
}

/// Something long the runtime is doing in the background (installing Ubuntu or
/// a language), for the UI to show with its progress.
class LinuxActivity {
  const LinuxActivity(this.title, this.step, [this.fraction, this.detail]);

  final String title;
  final String step;

  /// 0 to 1; null while the length is unknown.
  final double? fraction;

  /// e.g. `12.4 of 29.8 MB · 2.1 MB/s`.
  final String? detail;

  int? get percent => fraction == null ? null : (fraction! * 100).floor().clamp(0, 100);
}

/// The Ubuntu base image for one CPU architecture, pinned by checksum.
class _Image {
  const _Image(this.arch, this.sha256);

  final String arch;
  final String sha256;

  static const version = '24.04.5';

  Uri get url =>
      Uri.parse('https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-$version-base-$arch.tar.gz');
}

/// Runs shell commands inside FlowDroid itself: in Android's `/system/bin/sh`,
/// or in an Ubuntu root filesystem through proot. No other app is needed.
///
/// proot ships in the APK as `libproot.so` (see `scripts/fetch-proot.sh`),
/// because Android only lets an app execute files from its native library
/// directory. Ubuntu's own programs are started by proot's loader, which is
/// there too, so they run although they live in the app's data directory.
class LinuxRuntime {
  LinuxRuntime(Directory dataDir, {http.Client? client, String? libraryDir, this.shell = '/system/bin/sh'})
    : root = Directory('${dataDir.path}/linux'),
      _client = client ?? http.Client(),
      _nativeLibraryDir = libraryDir;

  /// Output kept per stream; anything past this is cut, so a chatty command can't exhaust memory.
  static const maxOutput = 512 * 1024;

  static const _images = {
    'arm64': _Image('arm64', 'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2'),
    'amd64': _Image('amd64', 'e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86'),
    'armhf': _Image('armhf', '4fcee4d278f1c5232e085a021a85e4c6cef3853557a88d98ff380b5e5d5841bb'),
  };

  final Directory root;

  /// The phone's shell; tests point it at the host's.
  final String shell;
  final http.Client _client;
  String? _nativeLibraryDir;
  Future<void>? _installing;

  Directory get rootfs => Directory('${root.path}/ubuntu');
  File get _installedMarker => File('${root.path}/ubuntu.installed');
  String get _tmp => '${root.path}/tmp';
  String get _libs => '${root.path}/lib';

  /// FlowDroid's folder for the Files node, visible in Ubuntu as /root/files.
  String get _files => '${root.parent.path}/files';

  bool get isInstalling => _installing != null;

  /// What the runtime is busy with, if anything; shown in the editor and terminal.
  final activity = ValueNotifier<LinuxActivity?>(null);

  Future<bool> get ubuntuInstalled => _installedMarker.exists();

  /// The app's native library directory, found from where the core library was loaded.
  String get nativeLibraryDir {
    final known = _nativeLibraryDir;
    if (known != null) return known;
    for (final line in File('/proc/self/maps').readAsLinesSync()) {
      final at = line.indexOf('/libflowcore_ffi.so');
      if (at < 0) continue;
      final start = line.indexOf('/');
      return _nativeLibraryDir = line.substring(start, at);
    }
    throw const LinuxException('the app’s native libraries were not found');
  }

  String get _proot => '$nativeLibraryDir/libproot.so';

  /// Runs [command] and returns what it printed. [onOutput] sees output as it arrives.
  Future<CommandOutput> run(
    String command, {
    LinuxTarget target = LinuxTarget.phone,
    String workdir = '',
    Duration timeout = const Duration(seconds: 60),
    void Function(String text, {required bool isError})? onOutput,
    Future<void>? cancel,
  }) async {
    final Process process;
    try {
      process = switch (target) {
        LinuxTarget.phone => await Process.start(
          shell,
          ['-c', command],
          workingDirectory: workdir.isEmpty ? root.parent.path : workdir,
          environment: {'HOME': root.parent.path, 'TMPDIR': _tmp},
        ),
        LinuxTarget.ubuntu => await _startUbuntu(command, workdir),
      };
    } on LinuxException catch (e) {
      return CommandOutput(error: e.message);
    } on ProcessException catch (e) {
      return CommandOutput(error: 'could not start the command: ${e.message}');
    }
    final out = StringBuffer();
    final err = StringBuffer();
    // Completes when the stream ends; set up before anything can end it.
    final drained = <Future<void>>[];
    StreamSubscription<String> collect(Stream<List<int>> stream, StringBuffer into, bool isError) {
      final done = Completer<void>();
      drained.add(done.future);
      return stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (text) {
              if (into.length < maxOutput) into.write(text);
              onOutput?.call(text, isError: isError);
            },
            onDone: done.complete,
            onError: (Object _) => done.isCompleted ? null : done.complete(),
            cancelOnError: true,
          );
    }

    final subs = [collect(process.stdout, out, false), collect(process.stderr, err, true)];
    var cancelled = false;
    unawaited(
      cancel?.then((_) {
        cancelled = true;
        process.kill(ProcessSignal.sigkill);
      }),
    );
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      for (final s in subs) {
        await s.cancel();
      }
      return CommandOutput(error: 'the command did not finish within ${timeout.inSeconds} s');
    }
    // A background child can keep the pipes open; don't wait on it for long.
    await Future.wait(drained).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    for (final s in subs) {
      await s.cancel();
    }
    if (cancelled) return const CommandOutput(error: 'stopped');
    String cut(StringBuffer b) => b.length > maxOutput ? '${b.toString().substring(0, maxOutput)}\n… (cut)' : '$b';
    return CommandOutput(stdout: cut(out), stderr: cut(err), exitCode: exitCode);
  }

  /// Starts [command] in Ubuntu with its stdin, stdout and stderr open, for
  /// programs the app talks to while they run (an MCP server over stdio).
  /// The caller kills it when done.
  Future<Process> startUbuntu(String command, {String workdir = ''}) => _startUbuntu(command, workdir);

  Future<Process> _startUbuntu(String command, String workdir) async {
    final launch = await _ubuntuLaunch(['/bin/bash', '-lc', command], workdir);
    return Process.start(
      launch.executable,
      launch.arguments,
      environment: launch.environment,
      includeParentEnvironment: false,
    );
  }

  /// proot with Ubuntu's root, the usual binds, and a clean environment, running [program].
  Future<ShellLaunch> _ubuntuLaunch(List<String> program, String workdir, {String term = 'xterm-256color'}) async {
    if (!await ubuntuInstalled) {
      throw const LinuxException('Ubuntu is not installed yet: open Settings → Terminal and install it');
    }
    await _prepareHostDirs();
    await _nameAndroidGroups();
    final r = rootfs.path;
    return ShellLaunch(
      executable: _proot,
      arguments: [
        '--kill-on-exit',
        '--link2symlink',
        '-0',
        '-r',
        r,
        '-b',
        '/dev',
        '-b',
        '/proc',
        '-b',
        '/sys',
        '-b',
        '/proc/self/fd:/dev/fd',
        '-b',
        '$r/tmp:/dev/shm',
        '-b',
        '$_files:/root/files',
        '-w',
        if (workdir.isEmpty) '/root' else workdir,
        '/usr/bin/env',
        '-i',
        'HOME=/root',
        'USER=root',
        'LANG=C.UTF-8',
        'TERM=$term',
        'TMPDIR=/tmp',
        'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        // Scripts run by workflows can't answer questions; the terminal can.
        if (program.length > 1 && program[1] == '-lc') 'DEBIAN_FRONTEND=noninteractive',
        ...program,
      ],
      environment: _prootEnvironment,
    );
  }

  /// An interactive shell for the Terminal screen: it runs in a real terminal, so
  /// programs can ask questions (y/n, passwords, menus) and the user answers them.
  Future<ShellLaunch> interactiveShell(LinuxTarget target) async {
    switch (target) {
      case LinuxTarget.ubuntu:
        return _ubuntuLaunch(['/bin/bash', '--login'], '');
      case LinuxTarget.phone:
        await Directory(_tmp).create(recursive: true);
        return ShellLaunch(
          executable: shell,
          arguments: const ['-i'],
          workingDirectory: root.parent.path,
          environment: {'HOME': root.parent.path, 'TMPDIR': _tmp, 'TERM': 'xterm-256color', 'PS1': r'$ '},
        );
    }
  }

  bool _groupsNamed = false;

  /// FlowDroid runs with Android's group IDs, which Ubuntu has no names for; without
  /// names every login prints "groups: cannot find name for group ID …".
  Future<void> _nameAndroidGroups() async {
    if (_groupsNamed) return;
    _groupsNamed = true;
    try {
      final ids = (await Process.run('/system/bin/id', ['-G'])).stdout.toString().trim().split(RegExp(r'\s+'));
      final file = File('${rootfs.path}/etc/group');
      if (!await file.exists()) return;
      final text = await file.readAsString();
      final known = {
        for (final line in text.split('\n'))
          if (line.split(':').length > 2) line.split(':')[2],
      };
      final missing = [
        for (final id in ids)
          if (int.tryParse(id) != null && !known.contains(id)) 'aid_$id:x:$id:',
      ];
      if (missing.isNotEmpty) await file.writeAsString('${text.trimRight()}\n${missing.join('\n')}\n');
    } on Object {
      // Only cosmetic.
    }
  }

  Map<String, String> get _prootEnvironment {
    final loader32 = File('$nativeLibraryDir/libproot-loader32.so');
    return {
      'PATH': '/system/bin',
      'HOME': root.path,
      'PROOT_TMP_DIR': _tmp,
      'PROOT_LOADER': '$nativeLibraryDir/libproot-loader.so',
      if (loader32.existsSync()) 'PROOT_LOADER_32': loader32.path,
      // proot asks for libtalloc.so.2; the APK can only ship it as libtalloc.so.
      'LD_LIBRARY_PATH': '$_libs:$nativeLibraryDir',
    };
  }

  Future<void> _prepareHostDirs() async {
    await Directory(_tmp).create(recursive: true);
    await Directory(_libs).create(recursive: true);
    await Directory(_files).create(recursive: true);
    final talloc = Link('$_libs/libtalloc.so.2');
    final target = '$nativeLibraryDir/libtalloc.so';
    // The native library directory changes path when the app is updated.
    if (await talloc.exists() && await talloc.target() != target) await talloc.delete();
    if (!await talloc.exists()) await talloc.create(target);
  }

  /// Downloads Ubuntu (about 30 MB), checks it, and unpacks it. Safe to call again after a failure.
  Stream<InstallProgress> installUbuntu() {
    final controller = StreamController<InstallProgress>();
    Future<void> work() async {
      void report(InstallProgress p) {
        controller.add(p);
        activity.value = p.step == 'Done' ? null : LinuxActivity('Installing Ubuntu', p.step, p.fraction, p.detail);
      }

      try {
        await _install(report);
      } on Exception catch (e) {
        controller.addError(e);
      } finally {
        activity.value = null;
        _installing = null;
        await controller.close();
      }
    }

    if (_installing != null) {
      controller
        ..addError(const LinuxException('Ubuntu is already being installed'))
        ..close();
    } else {
      _installing = work();
    }
    return controller.stream;
  }

  Future<void> _install(void Function(InstallProgress) report) async {
    final image = _images[await _ubuntuArch()];
    if (image == null) throw const LinuxException('this phone’s processor is not supported');
    await _prepareHostDirs();
    final tarball = File('${root.path}/ubuntu-${_Image.version}-${image.arch}.tar.gz');

    if (!await tarball.exists() || sha256.convert(await tarball.readAsBytes()).toString() != image.sha256) {
      report(const InstallProgress('Connecting', null, null, 1));
      final response = await _client.send(http.Request('GET', image.url));
      if (response.statusCode != 200) throw LinuxException('download failed (HTTP ${response.statusCode})');
      final total = response.contentLength ?? 0;
      final partial = File('${tarball.path}.part');
      final sink = partial.openWrite();
      var received = 0;
      final watch = Stopwatch()..start();
      var lastReport = -1;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        // About ten updates a second is plenty for a progress bar.
        final now = watch.elapsedMilliseconds;
        if (now - lastReport < 100 && received != total) continue;
        lastReport = now;
        report(
          InstallProgress(
            'Downloading Ubuntu',
            total > 0 ? received / total : null,
            downloadDetail(received, total, watch.elapsed),
            1,
          ),
        );
      }
      await sink.close();
      report(const InstallProgress('Checking the download', null, null, 2));
      final digest = sha256.convert(await partial.readAsBytes()).toString();
      if (digest != image.sha256) {
        await partial.delete();
        throw const LinuxException('the download is damaged; try again');
      }
      await partial.rename(tarball.path);
    }

    report(const InstallProgress('Unpacking', null, 'about 150 MB', 3));
    if (await rootfs.exists()) await rootfs.delete(recursive: true);
    await rootfs.create(recursive: true);
    // proot turns the archive's hard links into symlinks, which Android allows.
    final unpack = await Process.run(
      _proot,
      ['--link2symlink', '-0', '/system/bin/tar', '-xzf', tarball.path, '-C', rootfs.path],
      environment: _prootEnvironment,
      includeParentEnvironment: false,
    );
    if (!await File('${rootfs.path}/usr/bin/bash').exists()) {
      throw LinuxException('unpacking failed: ${'${unpack.stderr}'.trim().split('\n').last}');
    }

    report(const InstallProgress('Setting up', null, null, 4));
    await _configure();
    await tarball.delete();
    await _installedMarker.writeAsString(_Image.version);
    report(const InstallProgress('Done', 1, null, 4));
  }

  /// Network and package-manager settings that a root filesystem without systemd needs.
  Future<void> _configure() async {
    final etc = '${rootfs.path}/etc';
    Future<void> write(String path, String text) async {
      final link = Link(path);
      if (await link.exists()) await link.delete();
      await File(path).create(recursive: true);
      await File(path).writeAsString(text);
    }

    await write('$etc/resolv.conf', 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n');
    await write('$etc/hosts', '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n');
    // apt drops to the _apt user to download, which proot's fake root can't do.
    await write('$etc/apt/apt.conf.d/01flowdroid', 'APT::Sandbox::User "root";\n');
    await Directory('${rootfs.path}/tmp').create(recursive: true);
  }

  Future<String> _ubuntuArch() async {
    final machine = (await Process.run('/system/bin/uname', ['-m'])).stdout.toString().trim();
    return switch (machine) {
      'aarch64' || 'arm64' => 'arm64',
      'x86_64' => 'amd64',
      _ when machine.startsWith('arm') => 'armhf',
      _ => machine,
    };
  }

  /// Deletes Ubuntu and everything installed in it.
  Future<void> removeUbuntu() async {
    if (await _installedMarker.exists()) await _installedMarker.delete();
    if (await rootfs.exists()) {
      // Some Ubuntu directories are read-only; make them writable so they can be deleted.
      await Process.run('/system/bin/chmod', ['-R', 'u+rwx', rootfs.path]);
      await rootfs.delete(recursive: true);
    }
  }
}

/// `12.4 of 29.8 MB · 2.1 MB/s · 8 s left`.
String downloadDetail(int received, int total, Duration elapsed) {
  String mb(int b) => (b / 1048576).toStringAsFixed(1);
  final secs = elapsed.inMilliseconds / 1000;
  final speed = secs > 0.3 ? received / secs : 0.0;
  final parts = [total > 0 ? '${mb(received)} of ${mb(total)} MB' : '${mb(received)} MB'];
  if (speed > 0) {
    parts.add(speed >= 1048576 ? '${(speed / 1048576).toStringAsFixed(1)} MB/s' : '${(speed / 1024).round()} KB/s');
    if (total > received && received > 0) {
      final left = ((total - received) / speed).ceil();
      parts.add(left < 60 ? '$left s left' : '${(left / 60).ceil()} min left');
    }
  }
  return parts.join(' · ');
}

class LinuxException implements Exception {
  const LinuxException(this.message);

  final String message;

  @override
  String toString() => message;
}
