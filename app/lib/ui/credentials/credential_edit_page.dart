import 'package:material_ui/material_ui.dart';

import '../../core/json.dart';
import '../../data/credentials.dart';
import '../../runtime/google_auth.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import '../icons.dart';

/// Creates or edits one credential. Secrets are stored encrypted and never shown in run history.
class CredentialEditPage extends StatefulWidget {
  const CredentialEditPage({super.key, this.existing, this.types});

  final Credential? existing;

  /// Types offered when creating; all types when null.
  final List<String>? types;

  static Future<Credential?> open(BuildContext context, {Credential? existing, List<String>? types}) =>
      Navigator.of(context).push<Credential>(
        MaterialPageRoute(
          builder: (_) => CredentialEditPage(existing: existing, types: types),
        ),
      );

  @override
  State<CredentialEditPage> createState() => _CredentialEditPageState();
}

class _CredentialEditPageState extends State<CredentialEditPage> {
  late CredentialType _type;
  late final TextEditingController _name;
  final Map<String, TextEditingController> _fields = {};
  final Set<String> _revealed = {};
  String? _error;
  String? _googleAccount;
  bool _busy = false;

  List<CredentialType> get _offered {
    final ids = widget.types;
    return ids == null ? credentialTypes : credentialTypes.where((t) => ids.contains(t.id)).toList();
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _type = (existing != null ? credentialType(existing.type) : null) ?? _offered.first;
    _name = TextEditingController(text: existing?.name ?? _type.label);
    _resetFields(existing?.values ?? const {});
  }

  void _resetFields(Map<String, String> values) {
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields
      ..clear()
      ..addAll({for (final f in _type.fields) f.key: TextEditingController(text: values[f.key] ?? '')});
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {for (final e in _fields.entries) e.key: e.value.text.trim()};

  Future<void> _save() async {
    final name = _name.text.trim();
    final missing = _type.fields.where((f) => !f.optional && (_values[f.key] ?? '').isEmpty).map((f) => f.label);
    if (name.isEmpty) return setState(() => _error = 'Give it a name');
    if (missing.isNotEmpty) return setState(() => _error = 'Fill in: ${missing.join(', ')}');
    final store = ServicesScope.of(context).credentials;
    final clash = await store.byName(name);
    if (!mounted) return;
    if (clash != null && name != widget.existing?.name) {
      return setState(() => _error = 'A credential named “$name” exists');
    }
    final credential = Credential(name: name, type: _type.id, values: _values);
    await store.save(credential, replacing: widget.existing?.name);
    if (mounted) Navigator.of(context).pop(credential);
  }

  /// Logs in to the Web session's site in FlowDroid's browser.
  Future<void> _logInBrowser() async {
    var site = _values['site'] ?? '';
    if (site.isEmpty) {
      setState(() => _error = 'Fill in the site first');
      return;
    }
    if (!site.startsWith('http://') && !site.startsWith('https://')) site = 'https://$site';
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = asMap(await ServicesScope.of(context).phone.browserLogin(site));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['error'] case final String error) _error = error;
    });
  }

  Future<void> _signInGoogle() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = await GoogleAuth().signIn(_values['webClientId'] ?? '');
      if (mounted) setState(() => _googleAccount = email);
    } on Exception catch (e) {
      if (mounted) setState(() => _error = 'Google sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete “${existing.name}”?'),
        content: const Text('Workflows that use it will fail until you pick another credential.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ServicesScope.of(context).credentials.delete(existing.name);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (widget.existing != null)
            IconButton(tooltip: 'Delete', icon: const Icon(AppIcons.delete), onPressed: _delete),
          Padding(
            padding: const EdgeInsets.only(right: Space.page),
            child: FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.xxl),
        children: [
          Text(widget.existing == null ? 'New credential' : 'Edit credential', style: theme.textTheme.headlineMedium),
          const SizedBox(height: Space.lg),
          if (widget.existing == null && _offered.length > 1) ...[
            const FieldLabel('Service'),
            DropdownButtonFormField<String>(
              initialValue: _type.id,
              items: [for (final t in _offered) DropdownMenuItem(value: t.id, child: Text(t.label))],
              onChanged: (id) => setState(() {
                final next = credentialType(id ?? '') ?? _type;
                if (_name.text == _type.label) _name.text = next.label;
                _type = next;
                _resetFields(const {});
              }),
              borderRadius: BorderRadius.circular(14),
              icon: const Icon(AppIcons.chevronDown),
            ),
            const SizedBox(height: Space.lg),
          ],
          const FieldLabel('Name'),
          TextField(controller: _name, textCapitalization: TextCapitalization.sentences),
          for (final f in _type.fields) ...[
            const SizedBox(height: Space.lg),
            FieldLabel(f.optional ? '${f.label} (optional)' : f.label),
            TextField(
              controller: _fields[f.key],
              obscureText: f.secret && !_revealed.contains(f.key),
              autocorrect: false,
              enableSuggestions: false,
              style: theme.textTheme.bodyMedium?.copyWith(fontFamily: AppTheme.monoFamily),
              decoration: InputDecoration(
                hintText: f.hint,
                suffixIcon: f.secret
                    ? IconButton(
                        tooltip: _revealed.contains(f.key) ? 'Hide' : 'Show',
                        icon: Icon(_revealed.contains(f.key) ? AppIcons.eyeOff : AppIcons.eye),
                        onPressed: () => setState(() {
                          if (!_revealed.remove(f.key)) _revealed.add(f.key);
                        }),
                      )
                    : null,
              ),
            ),
          ],
          if (_type.id == 'google') ...[
            const SizedBox(height: Space.lg),
            OutlinedButton.icon(
              onPressed: _busy ? null : _signInGoogle,
              icon: const Icon(AppIcons.enter),
              label: Text(_googleAccount == null ? 'Sign in with Google' : 'Signed in as $_googleAccount'),
            ),
          ],
          if (_type.id == 'webSession') ...[
            const SizedBox(height: Space.lg),
            OutlinedButton.icon(
              onPressed: _busy ? null : _logInBrowser,
              icon: const Icon(AppIcons.browser),
              label: Text(_busy ? 'Waiting for you to tap Done…' : 'Log in in FlowDroid’s browser'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: c.danger)),
          ],
          const SizedBox(height: Space.xl),
          Text(_type.help, style: theme.textTheme.bodySmall?.copyWith(color: c.textSecondary)),
          const SizedBox(height: Space.sm),
          Text(
            'Stored encrypted on this phone only. Workflows refer to it by name; the secret never appears in run history.',
            style: theme.textTheme.bodySmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}
