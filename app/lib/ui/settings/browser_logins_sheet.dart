import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../runtime/browser/browser_logins.dart';
import '../icons.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../widgets/format.dart';

/// Logging in to sites in FlowDroid's browser, so Browser steps, the AI Agent's
/// browser tool and the assistant use those logins. A login stays until the site
/// ends it or you log out here.
class BrowserLoginsSheet extends StatefulWidget {
  const BrowserLoginsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const BrowserLoginsSheet(),
  );

  @override
  State<BrowserLoginsSheet> createState() => _BrowserLoginsSheetState();
}

class _BrowserLoginsSheetState extends State<BrowserLoginsSheet> {
  final _site = TextEditingController();
  late final BrowserLogins _logins = ServicesScope.of(context).browserLogins;
  List<SavedLogin>? _list;
  String? _message;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_list == null) _reload();
  }

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final list = await _logins.list();
    if (mounted) setState(() => _list = list);
  }

  Future<void> _logIn(String url) async {
    if (url.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final r = await _logins.logIn(url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = r['error'] is String
          ? asString(r['error'])
          : 'Saved. Automations use this login until the site ends it.';
    });
    _site.clear();
    await _reload();
  }

  Future<void> _forget(SavedLogin login) async {
    await _logins.forget(login);
    if (!mounted) return;
    setState(() => _message = 'Logged out of ${login.site}.');
    await _reload();
  }

  Future<void> _logOutAll() async {
    await _logins.clearAll();
    if (!mounted) return;
    setState(() => _message = 'Logged out of every site in FlowDroid’s browser.');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    final list = _list;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xs),
            child: Text('Browser logins', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.lg),
            child: Text(
              'Log in once; Browser steps, the AI Agent and the assistant use it, headless or on screen. It stays '
              'on this phone until the site ends the session or you log out here.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _site,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _busy ? null : _logIn,
                    decoration: const InputDecoration(hintText: 'Site, e.g. github.com/login'),
                  ),
                ),
                const SizedBox(width: Space.sm),
                FilledButton(
                  onPressed: _busy ? null : () => _logIn(_site.text),
                  child: Text(_busy ? 'Waiting…' : 'Log in'),
                ),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.page, 0),
              child: Text(_message!, style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary)),
            ),
          if (list == null)
            const Padding(padding: EdgeInsets.all(Space.xl), child: Center(child: QuietSpinner()))
          else if (list.isNotEmpty) ...[
            const SectionLabel('LOGGED IN'),
            GroupedSection(
              children: [
                for (final l in list)
                  ListTile(
                    leading: Icon(AppIcons.globe, color: c.textSecondary),
                    title: Text(l.site),
                    subtitle: Text('Logged in ${formatRelative(l.at)}'),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: Icon(AppIcons.more, color: c.textTertiary),
                      onSelected: (v) => v == 'again' ? _logIn(l.url) : _forget(l),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'again', child: Text('Log in again')),
                        PopupMenuItem(value: 'forget', child: Text('Log out')),
                      ],
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.page, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: _busy ? null : _logOutAll, child: const Text('Log out of all sites')),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.page, Space.md, Space.page, 0),
            child: Text(
              'Google and some banks block logging in inside apps; connect those with their own sign-in instead.',
              style: theme.textTheme.bodySmall?.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
