import 'package:material_ui/material_ui.dart';

import '../../data/credentials.dart';
import '../kit/kit.dart';
import '../services_scope.dart';
import '../theme.dart';
import 'credential_edit_page.dart';
import '../icons.dart';

/// Every saved credential, grouped in one list.
class CredentialsPage extends StatelessWidget {
  const CredentialsPage({super.key});

  static String _typeLabel(Credential cr) => credentialType(cr.type)?.label ?? cr.type;

  @override
  Widget build(BuildContext context) {
    final store = ServicesScope.of(context).credentials;
    final theme = Theme.of(context);
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add credential',
        onPressed: () => CredentialEditPage.open(context),
        child: const Icon(AppIcons.add),
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) => FutureBuilder<List<Credential>>(
          future: store.all(),
          builder: (context, snapshot) {
            final list = snapshot.data ?? const <Credential>[];
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.page, 0, Space.page, Space.sm),
                  child: Text('Credentials', style: theme.textTheme.headlineMedium),
                ),
                if (snapshot.hasData && list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Space.page),
                    child: Text(
                      'API keys and tokens for AI models, Telegram, Discord, databases and Google. '
                      'Add one here or straight from a node.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: c.textSecondary),
                    ),
                  )
                else if (list.isNotEmpty) ...[
                  const SectionLabel('SAVED'),
                  GroupedSection(
                    children: [
                      for (final cr in list)
                        ListTile(
                          leading: Icon(AppIcons.key, color: c.textSecondary),
                          title: Text(cr.name),
                          subtitle: _typeLabel(cr) == cr.name ? null : Text(_typeLabel(cr)),
                          trailing: Icon(AppIcons.chevronRight, color: c.textTertiary),
                          onTap: () => CredentialEditPage.open(context, existing: cr),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 96),
              ],
            );
          },
        ),
      ),
    );
  }
}
