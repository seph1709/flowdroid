import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../../runtime/linux/linux_runtime.dart';
import '../icons.dart';
import '../kit/activity_strip.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';

/// One shell running in a real terminal (a pty), so programs can ask questions
/// (y/n, passwords, numbered or arrow-key menus) and the user answers them.
class _Session {
  _Session(this.target);

  final LinuxTarget target;
  final terminal = Terminal(maxLines: 10000);
  final controller = TerminalController();
  Pty? _pty;
  bool ended = false;

  /// The Ctrl key on the key bar: applies to the next key typed.
  bool ctrlArmed = false;

  Future<void> start(LinuxRuntime linux, {required VoidCallback onChange}) async {
    ended = false;
    final ShellLaunch launch;
    try {
      launch = await linux.interactiveShell(target);
    } on LinuxException catch (e) {
      terminal.write('\r\n${e.message}\r\n');
      ended = true;
      onChange();
      return;
    }
    final pty = Pty.start(
      launch.executable,
      arguments: launch.arguments,
      environment: launch.environment,
      workingDirectory: launch.workingDirectory,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _pty = pty;
    pty.output.cast<List<int>>().transform(const Utf8Decoder(allowMalformed: true)).listen(terminal.write);
    unawaited(
      pty.exitCode.then((code) {
        if (_pty != pty) return;
        ended = true;
        terminal.write('\r\n\x1b[2m[session ended (exit $code) · press Enter to start a new one]\x1b[0m\r\n');
        onChange();
      }),
    );
    terminal
      ..onOutput = (data) {
        if (ended) {
          if (data.contains('\r')) {
            terminal.write('\x1b[2J\x1b[H');
            start(linux, onChange: onChange);
          }
          return;
        }
        if (ctrlArmed && data.length == 1) {
          ctrlArmed = false;
          onChange();
          final c = data.toUpperCase().codeUnitAt(0);
          if (c >= 0x40 && c <= 0x5f) {
            _send(String.fromCharCode(c & 0x1f));
            return;
          }
        }
        _send(data);
      }
      ..onResize = (w, h, pw, ph) => _pty?.resize(h, w);
    onChange();
  }

  void _send(String data) => _pty?.write(Uint8List.fromList(utf8.encode(data)));

  /// Sends keys from the key bar.
  void key(TerminalKey key) => terminal.keyInput(key);
  void text(String s) => _send(s);

  void dispose() {
    final pty = _pty;
    _pty = null;
    pty?.kill();
  }
}

/// A real terminal on the phone or in the built-in Ubuntu. Ubuntu is installed
/// from here on first use.
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, this.command});

  /// Typed into a new Ubuntu session once it starts, e.g. an install command.
  final String? command;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _sessions = <LinuxTarget, _Session>{};
  final _focus = FocusNode();
  LinuxTarget _target = LinuxTarget.ubuntu;

  /// The on-screen keyboard shows only after the keyboard button, not on every tap.
  bool _keyboard = false;
  bool _keyboardWasUp = false;
  bool? _ubuntuInstalled;
  InstallProgress? _progress;
  String? _installError;
  StreamSubscription<InstallProgress>? _install;

  LinuxRuntime get _linux => ServicesScope.of(context).linux;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ubuntuInstalled == null) _refresh();
  }

  @override
  void dispose() {
    _install?.cancel();
    for (final s in _sessions.values) {
      s.dispose();
    }
    _focus.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final installed = await _linux.ubuntuInstalled;
    if (mounted) setState(() => _ubuntuInstalled = installed);
  }

  void _installUbuntu() {
    setState(() {
      _installError = null;
      _progress = const InstallProgress('Starting');
    });
    _install = _linux.installUbuntu().listen(
      (p) => setState(() => _progress = p),
      onError: (Object e) => setState(() {
        _installError = '$e';
        _progress = null;
      }),
      onDone: () {
        if (!mounted) return;
        setState(() => _progress = null);
        _refresh();
      },
    );
  }

  /// The session for [target], started the first time it is shown.
  _Session _session(LinuxTarget target) => _sessions.putIfAbsent(target, () {
    final s = _Session(target);
    // Start after the first layout, when the terminal knows its size.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      s.start(_linux, onChange: () => mounted ? setState(() {}) : null).then((_) {
        final command = widget.command;
        if (command != null && target == LinuxTarget.ubuntu && !s.ended) s.text('$command\r');
      });
    });
    return s;
  });

  Future<void> _setKeyboard(bool on) async {
    setState(() => _keyboard = on);
    if (on) {
      // Wait for the terminal to switch to soft-keyboard input, then focus and show it.
      await WidgetsBinding.instance.endOfFrame;
      _focus.requestFocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }

  void _restart() {
    final s = _sessions.remove(_target);
    s?.dispose();
    setState(() {});
  }

  /// Shows the terminal's text as ordinary selectable text: Android's own handles, Select all and Copy.
  void _selectText() {
    final s = _sessions[_target];
    if (s == null) return;
    final lines = s.terminal.buffer.getText().split('\n').map((l) => l.trimRight()).toList();
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => _SelectTextPage(text: lines.join('\n'))));
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.isNotEmpty) _sessions[_target]?.terminal.paste(text);
  }

  @override
  Widget build(BuildContext context) {
    // The keyboard was closed with Back or a swipe: stop showing it on taps too.
    final up = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (_keyboard && _keyboardWasUp && !up) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _keyboard = false);
      });
    }
    _keyboardWasUp = up;
    final theme = Theme.of(context);
    final needsInstall = _target == LinuxTarget.ubuntu && _ubuntuInstalled == false;
    final ready = _ubuntuInstalled != null && !needsInstall;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (ready) ...[
            IconButton(tooltip: 'Paste', icon: const Icon(AppIcons.paste), onPressed: _paste),
            IconButton(tooltip: 'Select text', icon: const Icon(AppIcons.copy), onPressed: _selectText),
            IconButton(tooltip: 'New session', icon: const Icon(AppIcons.restore), onPressed: _restart),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
              child: Text('Terminal', style: theme.textTheme.headlineMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.page),
              child: PillSwitch<LinuxTarget>(
                value: _target,
                options: const [
                  (value: LinuxTarget.ubuntu, label: 'Ubuntu', icon: AppIcons.server),
                  (value: LinuxTarget.phone, label: 'Phone', icon: AppIcons.phone),
                ],
                onChanged: (t) => setState(() => _target = t),
              ),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: _ubuntuInstalled == null
                  ? const Center(child: QuietSpinner())
                  : needsInstall
                  ? _InstallCard(progress: _progress, error: _installError, onInstall: _installUbuntu)
                  : _TerminalArea(
                      // A separate view per target keeps each session's screen.
                      key: ValueKey(_target),
                      session: _session(_target),
                      focus: _focus,
                      softKeyboard: _keyboard,
                    ),
            ),
            if (ready)
              _KeyBar(
                session: _session(_target),
                onChange: () => setState(() {}),
                keyboard: _keyboard,
                onKeyboard: () => _setKeyboard(!_keyboard),
              ),
          ],
        ),
      ),
    );
  }
}

class _TerminalArea extends StatelessWidget {
  const _TerminalArea({super.key, required this.session, required this.focus, required this.softKeyboard});

  final _Session session;
  final FocusNode focus;

  /// Off: taps select and scroll, typing comes only from the key bar or a hardware keyboard.
  final bool softKeyboard;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: TerminalView(
        session.terminal,
        controller: session.controller,
        focusNode: focus,
        autofocus: false,
        hardwareKeyboardOnly: !softKeyboard,
        theme: _terminalTheme(c, dark),
        textStyle: const TerminalStyle(fontFamily: AppTheme.monoFamily, fontSize: 13),
        padding: const EdgeInsets.all(Space.sm),
        // No autocorrect or suggestions while typing commands.
        keyboardType: TextInputType.visiblePassword,
        keyboardAppearance: dark ? Brightness.dark : Brightness.light,
        cursorType: TerminalCursorType.block,
      ),
    );
  }
}

/// Keys a phone keyboard doesn't have: Esc, Tab, Ctrl, arrows, and a few symbols.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.session, required this.onChange, required this.keyboard, required this.onKeyboard});

  final _Session session;
  final VoidCallback onChange;
  final bool keyboard;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    Widget key(String label, VoidCallback onTap, {bool active = false, String? tooltip}) => Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip ?? label,
        child: Material(
          color: active ? c.accent : c.grouped,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            canRequestFocus: false,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Container(
              constraints: const BoxConstraints(minWidth: 40),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                style: AppTheme.monospace.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: active ? Colors.white : c.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Container(
      height: 52,
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.sm),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Tooltip(
              message: keyboard ? 'Hide keyboard' : 'Show keyboard',
              child: Material(
                color: keyboard ? c.accentSoft : c.accent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  canRequestFocus: false,
                  onTap: onKeyboard,
                  child: SizedBox(
                    width: 48,
                    child: Icon(
                      keyboard ? AppIcons.keyboardHide : AppIcons.keyboard,
                      size: 20,
                      color: keyboard ? c.accent : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
          key('Esc', () => session.key(TerminalKey.escape)),
          key('Tab', () => session.key(TerminalKey.tab)),
          key(
            'Ctrl',
            () {
              session.ctrlArmed = !session.ctrlArmed;
              onChange();
            },
            active: session.ctrlArmed,
            tooltip: 'Ctrl + the next key',
          ),
          key('^C', () => session.text('\x03'), tooltip: 'Stop the running program (Ctrl+C)'),
          key('↑', () => session.key(TerminalKey.arrowUp), tooltip: 'Up / previous command'),
          key('↓', () => session.key(TerminalKey.arrowDown), tooltip: 'Down'),
          key('←', () => session.key(TerminalKey.arrowLeft), tooltip: 'Left'),
          key('→', () => session.key(TerminalKey.arrowRight), tooltip: 'Right'),
          key('y⏎', () => session.text('y\r'), tooltip: 'Answer yes'),
          key('n⏎', () => session.text('n\r'), tooltip: 'Answer no'),
          key('|', () => session.text('|')),
          key('/', () => session.text('/')),
          key('-', () => session.text('-')),
          key('~', () => session.text('~')),
          key('^D', () => session.text('\x04'), tooltip: 'End of input (Ctrl+D)'),
        ],
      ),
    );
  }
}

/// Terminal colors drawn from the app's palette, readable in light and dark.
TerminalTheme _terminalTheme(AppColors c, bool dark) => TerminalTheme(
  cursor: c.accent,
  selection: c.accent.withValues(alpha: 0.3),
  foreground: c.text,
  background: c.canvas,
  black: dark ? const Color(0xFF3A3A40) : const Color(0xFF1C1C1E),
  red: c.danger,
  green: c.success,
  yellow: c.warning,
  blue: c.accent,
  magenta: dark ? const Color(0xFFC09BF5) : const Color(0xFF8A47CF),
  cyan: dark ? const Color(0xFF5BC8D8) : const Color(0xFF0E8AA8),
  white: dark ? const Color(0xFFDCDCE2) : const Color(0xFF6E6E73),
  brightBlack: c.textTertiary,
  brightRed: c.danger,
  brightGreen: c.success,
  brightYellow: c.warning,
  brightBlue: c.accent,
  brightMagenta: dark ? const Color(0xFFD7BBFA) : const Color(0xFF9D5FE0),
  brightCyan: dark ? const Color(0xFF7FD8E6) : const Color(0xFF1AA3C2),
  brightWhite: c.text,
  searchHitBackground: c.warningSoft,
  searchHitBackgroundCurrent: c.warning,
  searchHitForeground: c.text,
);

/// Offers to install Ubuntu and shows the download and unpacking progress.
class _InstallCard extends StatelessWidget {
  const _InstallCard({required this.progress, required this.error, required this.onInstall});

  final InstallProgress? progress;
  final String? error;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final p = progress;
    return ListView(
      padding: const EdgeInsets.all(Space.page),
      children: [
        Text('Ubuntu on your phone', style: theme.textTheme.titleMedium),
        const SizedBox(height: Space.sm),
        Text(
          'A full Ubuntu 24.04 that runs inside FlowDroid, with apt for installing packages such as '
          'python3, git, nodejs or ffmpeg. No other app and no root needed.\n\n'
          'The first install downloads about 30 MB and needs about 150 MB of space.',
          style: theme.textTheme.bodyMedium?.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: Space.xl),
        if (p == null)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: onInstall,
              icon: const Icon(AppIcons.download),
              label: Text(error == null ? 'Install Ubuntu' : 'Try again'),
            ),
          )
        else ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                p.fraction == null ? '…' : '${(p.fraction! * 100).floor()}%',
                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  p.detail ?? p.step,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          ProgressBar(value: p.stepNumber <= 1 ? p.fraction : _overall(p), height: 6),
          const SizedBox(height: Space.lg),
          for (final (i, label) in const ['Download', 'Check', 'Unpack', 'Set up'].indexed)
            _StepRow(number: i + 1, label: label, current: p.stepNumber),
        ],
        if (error != null) ...[
          const SizedBox(height: Space.md),
          Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: c.danger)),
        ],
      ],
    );
  }
}

/// Overall progress across the install steps, after the download.
double? _overall(InstallProgress p) => p.stepNumber >= InstallProgress.steps && p.fraction == 1 ? 1 : null;

class _StepRow extends StatelessWidget {
  const _StepRow({required this.number, required this.label, required this.current});

  final int number;
  final String label;
  final int current;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final done = current > number;
    final active = current == number;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: done
                ? Icon(AppIcons.checkCircle, size: 20, color: c.success)
                : active
                ? const QuietSpinner(size: 18)
                : DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: c.outline, width: 1.6),
                    ),
                  ),
          ),
          const SizedBox(width: Space.md),
          Text(
            'Step $number of ${InstallProgress.steps}  ·  $label',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: done || active ? c.text : c.textTertiary,
              fontWeight: active ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// The terminal's text for selecting: long-press a word, drag the handles, Copy.
class _SelectTextPage extends StatefulWidget {
  const _SelectTextPage({required this.text});

  final String text;

  @override
  State<_SelectTextPage> createState() => _SelectTextPageState();
}

class _SelectTextPageState extends State<_SelectTextPage> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Start at the newest output, like the terminal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select text'),
        actions: [
          TextButton.icon(
            icon: const Icon(AppIcons.copy, size: 18),
            label: const Text('Copy all'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Terminal text copied')));
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
            child: Text(
              'Long-press to start, drag the handles, then tap Copy.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
              decoration: BoxDecoration(
                color: c.canvas,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.hairline),
              ),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(Space.md),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    widget.text.isEmpty ? ' ' : widget.text,
                    style: AppTheme.monospace.copyWith(color: c.text, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
