import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../icons.dart';
import '../services_scope.dart';
import '../theme.dart';

/// Logging in to sites in FlowDroid's browser, so Browser steps and the AI
/// Agent's browser tool use those logins; and logging out of all of them.
class BrowserLoginsSheet extends StatefulWidget {
  const BrowserLoginsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const BrowserLoginsSheet(),
  );

  @override
  State<BrowserLoginsSheet> createState() => _BrowserLoginsSheetState();
}

class _BrowserLoginsSheetState extends State<BrowserLoginsSheet> {
  final _site = TextEditingController(text: 'https://');
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  Future<void> _logIn() async {
    var url = _site.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'https://$url';
    setState(() {
      _busy = true;
      _message = null;
    });
    final r = asMap(await ServicesScope.of(context).phone.browserLogin(url));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = r['error'] is String
          ? asString(r['error'])
          : 'Saved. Browser steps and the AI Agent now use this login (until the site logs you out).';
    });
  }

  Future<void> _logOutAll() async {
    await ServicesScope.of(context).phone.browserClearLogins();
    if (mounted) setState(() => _message = 'Logged out of every site in FlowDroid’s browser.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(Space.xl, 0, Space.xl, Space.xl + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Browser logins', style: theme.textTheme.titleLarge),
            const SizedBox(height: Space.sm),
            Text(
              'Log in to a site once in FlowDroid’s browser. Browser steps, the AI Agent’s browser tool and '
              '“Web session” credentials use that login; FlowDroid keeps it like a browser does, on this phone only.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Space.lg),
            TextField(
              controller: _site,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(hintText: 'https://example.com/login'),
            ),
            const SizedBox(height: Space.md),
            FilledButton.icon(
              onPressed: _busy ? null : _logIn,
              icon: const Icon(AppIcons.browser),
              label: Text(_busy ? 'Waiting for you to tap Done…' : 'Log in'),
            ),
            const SizedBox(height: Space.sm),
            OutlinedButton(onPressed: _busy ? null : _logOutAll, child: const Text('Log out of all sites')),
            if (_message != null) ...[
              const SizedBox(height: Space.md),
              Text(_message!, style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary)),
            ],
            const SizedBox(height: Space.md),
            Text(
              'Google and some banks block logging in inside apps; connect those with their own sign-in instead.',
              style: theme.textTheme.bodySmall?.copyWith(color: c.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
