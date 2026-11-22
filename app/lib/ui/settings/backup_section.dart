import 'package:material_ui/material_ui.dart';

import '../../data/backup.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../icons.dart';

/// Back up everything to a file (encrypted with a passphrase) and restore it.
class BackupSection extends StatefulWidget {
  const BackupSection({super.key});

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  bool _busy = false;

  Backup get _backup {
    final services = ServicesScope.of(context);
    return Backup(services.repository, services.credentials);
  }

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<String?> _passphrase({required bool confirm}) {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(confirm ? 'Choose a passphrase' : 'Backup passphrase'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                confirm
                    ? 'The backup holds your API keys, so it is encrypted. Without this passphrase it cannot be restored.'
                    : 'The passphrase you chose when making the backup.',
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: first,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Passphrase'),
              ),
              if (confirm) ...[
                const SizedBox(height: Space.sm),
                TextField(
                  controller: second,
                  obscureText: true,
                  decoration: const InputDecoration(hintText: 'Again'),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: Space.sm),
                Text(error!, style: TextStyle(color: AppColors.of(context).danger)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                if (confirm && first.text.length < 8) return setState(() => error = 'Use at least 8 characters');
                if (confirm && first.text != second.text) return setState(() => error = 'The two do not match');
                Navigator.pop(context, first.text);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final phone = ServicesScope.of(context).phone;
    final passphrase = await _passphrase(confirm: true);
    if (passphrase == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final bytes = await _backup.export(passphrase);
      final day = DateTime.now().toIso8601String().substring(0, 10);
      final saved = await phone.saveDocument('flowdroid-$day.flowdroid', 'application/json', bytes);
      if (mounted && saved) _say('Backup saved');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final phone = ServicesScope.of(context).phone;
    final bytes = await phone.openDocument();
    if (bytes == null || !mounted) return;
    final passphrase = await _passphrase(confirm: false);
    if (passphrase == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final (workflows, credentials) = await _backup.restore(bytes, passphrase);
      if (mounted) _say('Restored $workflows workflows and $credentials credentials');
    } on BackupException catch (e) {
      if (mounted) _say(e.message);
    } on FormatException {
      if (mounted) _say('This file is not a FlowDroid backup');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionLabel('BACKUP'),
        GroupedSection(
          children: [
            ListTile(
              leading: Icon(AppIcons.saveFile, color: c.textSecondary),
              title: const Text('Back up'),
              subtitle: const Text('Workflows and credentials, encrypted'),
              enabled: !_busy,
              onTap: _export,
            ),
            ListTile(
              leading: Icon(AppIcons.restore, color: c.textSecondary),
              title: const Text('Restore'),
              subtitle: const Text('From a FlowDroid backup file'),
              enabled: !_busy,
              onTap: _restore,
            ),
          ],
        ),
      ],
    );
  }
}
